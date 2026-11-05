import Darwin
import Foundation

public struct CleanupFailure: Sendable, Equatable {
    public let title: String
    public let path: String?
    public let reason: String

    public init(title: String, path: String?, reason: String) {
        self.title = title
        self.path = path
        self.reason = reason
    }
}

public struct CleanupOutcome: Sendable {
    public let entries: [HistoryEntry]
    public let failures: [CleanupFailure]

    /// What went to the Trash (or would have, in a dry run). Space returns once the Trash is emptied.
    public var bytesMovedToTrash: Int64 {
        entries.filter { $0.kind == .trashed && ($0.state == .inTrash || $0.state == .completed) }
            .reduce(0) { $0 + $1.bytes }
    }
}

/// Does the actual cleaning. Every path is checked again right before it's touched, because the
/// disk may have changed since the scan.
public actor CleanupEngine {
    private let safetyGuard: SafetyGuard
    private let trash: any Trashing
    private let runner: any CommandRunning
    private let history: CleanupHistory
    private let dryRun: Bool
    private let isRunning: @Sendable (String) -> Bool

    public init(
        safetyGuard: SafetyGuard, trash: any Trashing, runner: any CommandRunning, history: CleanupHistory,
        dryRun: Bool, isRunning: @escaping @Sendable (String) -> Bool
    ) {
        self.safetyGuard = safetyGuard
        self.trash = trash
        self.runner = runner
        self.history = history
        self.dryRun = dryRun
        self.isRunning = isRunning
    }

    /// `progress` hears how many of `items` have been dealt with, after each one.
    public func moveToTrash(_ items: [CleanupItem], progress: @Sendable (Int) -> Void = { _ in }) async -> CleanupOutcome {
        var entries: [HistoryEntry] = []
        var failures: [CleanupFailure] = []

        for (done, item) in items.enumerated() {
            defer { progress(done + 1) }
            guard item.action == .trash else {
                failures.append(CleanupFailure(title: item.title, path: nil, reason: "This item isn't moved to the Trash."))
                continue
            }
            if let owner = item.owner, isRunning(owner) {
                failures.append(CleanupFailure(title: item.title, path: nil, reason: "Quit the app that uses this first, then try again."))
                continue
            }
            for (index, path) in item.paths.enumerated() {
                let bytes = item.bytes / Int64(item.paths.count) + (index == 0 ? item.bytes % Int64(item.paths.count) : 0)
                guard let fileID = Self.fileID(path) else {
                    failures.append(CleanupFailure(title: item.title, path: path, reason: "Already gone"))
                    continue
                }
                do throws(SafetyViolation) {
                    try safetyGuard.check(path)
                } catch {
                    failures.append(CleanupFailure(title: item.title, path: path, reason: error.message))
                    continue
                }
                if dryRun {
                    entries.append(HistoryEntry(kind: .trashed, title: item.title, originalPath: path, trashPath: nil,
                                                trashFileID: nil, bytes: bytes, commandLine: nil, state: .completed))
                    continue
                }
                do {
                    let trashed = try await trash.trash(path)
                    entries.append(HistoryEntry(kind: .trashed, title: item.title, originalPath: path, trashPath: trashed,
                                                trashFileID: fileID, bytes: bytes, commandLine: nil, state: .inTrash))
                } catch {
                    failures.append(CleanupFailure(title: item.title, path: path, reason: error.localizedDescription))
                }
            }
        }
        if !dryRun { await record(entries, failures: &failures) }
        return CleanupOutcome(entries: entries, failures: failures)
    }

    public func runTool(_ item: CleanupItem) async -> CleanupOutcome {
        guard case .tool(let command) = item.action, ToolAllowlist.validate(command) else {
            return CleanupOutcome(entries: [], failures: [
                CleanupFailure(title: item.title, path: nil, reason: "Unearth doesn't run this command."),
            ])
        }
        var entry = HistoryEntry(kind: .toolRun, title: item.title, originalPath: nil, trashPath: nil, trashFileID: nil,
                                 bytes: item.bytes, commandLine: command.commandLine, state: .completed)
        var failures: [CleanupFailure] = []
        if !dryRun {
            let (executable, arguments) = command.needsAdmin
                ? ToolAllowlist.adminInvocation(command) : (command.executable, command.arguments)
            let environment = command.toolName == "Homebrew" ? HomebrewDetector.environment : [:]
            do {
                let result = try await runner.run(executable, arguments, environment: environment)
                if result.exitCode != 0 {
                    entry.state = .failed
                    failures.append(CleanupFailure(title: item.title, path: nil, reason: Self.reason(for: result, command)))
                }
            } catch {
                entry.state = .failed
                failures.append(CleanupFailure(title: item.title, path: nil, reason: error.localizedDescription))
            }
        }
        if !dryRun { await record([entry], failures: &failures) }
        return CleanupOutcome(entries: [entry], failures: failures)
    }

    public func undo(_ ids: [UUID]) async -> [CleanupFailure] {
        var failures: [CleanupFailure] = []
        var states: [UUID: HistoryEntry.State] = [:]
        let entries = await history.entries(ids)
        for id in ids {
            guard let entry = entries[id], entry.kind == .trashed, entry.state == .inTrash,
                  let trashPath = entry.trashPath, let originalPath = entry.originalPath else {
                failures.append(CleanupFailure(title: "", path: nil, reason: "This can't be undone."))
                continue
            }
            if Self.fileID(originalPath) != nil {
                failures.append(CleanupFailure(title: entry.title, path: originalPath,
                                               reason: "Something new is at the original location, so it was left in the Trash."))
                continue
            }
            if let failure = verifyStillInTrash(entry, trashPath, states: &states) {
                failures.append(failure)
                continue
            }
            do {
                try await trash.restore(trashPath, to: originalPath)
                states[id] = .restored
            } catch {
                failures.append(CleanupFailure(title: entry.title, path: originalPath, reason: error.localizedDescription))
            }
        }
        await save(states, failures: &failures)
        return failures
    }

    public func deletePermanently(_ ids: [UUID]) async -> [CleanupFailure] {
        var failures: [CleanupFailure] = []
        var states: [UUID: HistoryEntry.State] = [:]
        let entries = await history.entries(ids)
        for id in ids {
            guard let entry = entries[id], entry.kind == .trashed, entry.state == .inTrash,
                  let trashPath = entry.trashPath else {
                failures.append(CleanupFailure(title: "", path: nil, reason: "Only items Unearth moved to the Trash can be deleted here."))
                continue
            }
            if let failure = verifyStillInTrash(entry, trashPath, states: &states) {
                failures.append(failure)
                continue
            }
            do {
                try await trash.deletePermanently(trashPath)
                states[id] = .deletedPermanently
            } catch {
                failures.append(CleanupFailure(title: entry.title, path: trashPath, reason: error.localizedDescription))
            }
        }
        await save(states, failures: &failures)
        return failures
    }

    // MARK: - Helpers

    /// The item must still be in the Trash and still be the same file Unearth put there.
    private func verifyStillInTrash(_ entry: HistoryEntry, _ trashPath: String, states: inout [UUID: HistoryEntry.State]) -> CleanupFailure? {
        guard let current = Self.fileID(trashPath) else {
            states[entry.id] = .goneFromTrash
            return CleanupFailure(title: entry.title, path: trashPath, reason: "It's no longer in the Trash.")
        }
        if let expected = entry.trashFileID, expected != current {
            return CleanupFailure(title: entry.title, path: trashPath,
                                  reason: "The item in the Trash changed, so Unearth left it alone.")
        }
        return nil
    }

    private func save(_ states: [UUID: HistoryEntry.State], failures: inout [CleanupFailure]) async {
        do {
            try await history.setStates(states)
        } catch {
            failures.append(CleanupFailure(title: "Cleanup history", path: nil, reason: "Unearth couldn't save its history."))
        }
    }

    private func record(_ entries: [HistoryEntry], failures: inout [CleanupFailure]) async {
        do {
            try await history.record(entries)
        } catch {
            failures.append(CleanupFailure(title: "Cleanup history", path: nil,
                                           reason: "Unearth couldn't save its history, so Undo won't be available for these items."))
        }
    }

    /// The file id of the item itself (links aren't followed), or nil if nothing is there.
    private static func fileID(_ path: String) -> UInt64? {
        var info = stat()
        return lstat(path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    private static func reason(for result: CommandResult, _ command: ToolCommand) -> String {
        let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("-128") { return "Cancelled." }
        return message.isEmpty ? "\(command.toolName) stopped with an error (code \(result.exitCode))." : message
    }
}
