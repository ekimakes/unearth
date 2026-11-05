import Foundation

public struct HistoryEntry: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case trashed, toolRun
    }

    public enum State: String, Codable, Sendable {
        /// `completed` is a finished tool run, or a dry-run move that changed nothing.
        case inTrash, restored, deletedPermanently, goneFromTrash, completed, failed
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let title: String
    public let originalPath: String?
    public let trashPath: String?
    /// The item's file id when it was trashed, so a different file with the same name is never touched.
    public let trashFileID: UInt64?
    public let bytes: Int64
    public let commandLine: String?
    public var state: State

    public init(
        id: UUID = UUID(), date: Date = Date(), kind: Kind, title: String, originalPath: String?, trashPath: String?,
        trashFileID: UInt64?, bytes: Int64, commandLine: String?, state: State
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.trashFileID = trashFileID
        self.bytes = bytes
        self.commandLine = commandLine
        self.state = state
    }
}

/// Everything Unearth moved or ran, newest first, saved as JSON.
public actor CleanupHistory {
    private let fileURL: URL
    private var entries: [HistoryEntry]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let data = try? Data(contentsOf: fileURL)
        let saved = data.flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
        // Dry runs used to leave a record of moves that never happened.
        entries = saved.filter { !($0.kind == .trashed && $0.state == .completed) }
    }

    public func all() -> [HistoryEntry] { entries }

    public func entry(_ id: UUID) -> HistoryEntry? { entries.first { $0.id == id } }

    public func entries(_ ids: [UUID]) -> [UUID: HistoryEntry] {
        let wanted = Set(ids)
        return Dictionary(entries.filter { wanted.contains($0.id) }.map { ($0.id, $0) }) { first, _ in first }
    }

    public func record(_ newEntries: [HistoryEntry]) throws {
        guard !newEntries.isEmpty else { return }
        entries = newEntries + entries
        try save()
    }

    /// All at once, because every save writes the whole history: thousands of files one by one would take minutes.
    public func setStates(_ states: [UUID: HistoryEntry.State]) throws {
        guard !states.isEmpty else { return }
        for index in entries.indices {
            if let state = states[entries[index].id] { entries[index].state = state }
        }
        try save()
    }

    /// Items the user has since emptied from the Trash can't be undone anymore.
    public func reconcile(fileExists: @Sendable (String) -> Bool) throws {
        var changed = false
        for index in entries.indices where entries[index].state == .inTrash {
            if let trashPath = entries[index].trashPath, !fileExists(trashPath) {
                entries[index].state = .goneFromTrash
                changed = true
            }
        }
        if changed { try save() }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
    }
}
