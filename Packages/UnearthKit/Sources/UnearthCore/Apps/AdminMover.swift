import Darwin
import Foundation

public enum AdminMoveError: Error, LocalizedError, Equatable {
    case cancelled
    case failed

    public var errorDescription: String? {
        switch self {
        case .cancelled: "You cancelled the password prompt, so the app stayed where it was."
        case .failed: "Unearth couldn't move this app. Drag it to the Trash in Finder."
        }
    }
}

/// Moves one item with an administrator's password, through the macOS password prompt. The paths and the
/// prompt reach the script only as arguments, never as script text, so no name can change what runs.
public struct AdminMover: Sendable {
    /// Run as `osascript -e <line> …`, with the source, destination and prompt as the script's arguments.
    static let script = [
        "on run argv",
        #"do shell script "/bin/mv -n " & quoted form of item 1 of argv & " " & quoted form of item 2 of argv with prompt (item 3 of argv) with administrator privileges"#,
        "end run",
    ]

    private let runner: any CommandRunning

    /// The runner's timeout must leave time to type a password.
    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func move(_ source: String, to destination: String, prompt: String) async throws(AdminMoveError) {
        let arguments = Self.script.flatMap { ["-e", $0] } + [source, destination, prompt]
        let result: CommandResult
        do {
            result = try await runner.run("/usr/bin/osascript", arguments, environment: [:])
        } catch {
            throw .failed
        }
        if result.exitCode != 0 {
            throw String(decoding: result.stderr, as: UTF8.self).contains("(-128)") ? .cancelled : .failed
        }
        // mv -n quietly does nothing when the destination exists; only a finished move counts.
        guard !Self.exists(source), Self.exists(destination) else { throw .failed }
    }

    /// The user isn't allowed to move it: it belongs to the system, or its folder isn't theirs to change.
    static func isPermissionError(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteNoPermissionError || error.code == NSFileReadNoPermissionError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EACCES) || error.code == Int(EPERM) { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isPermissionError) ?? false
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}

/// The Trash for one uninstall: when the app itself can't be moved for lack of permission, it goes through
/// the password prompt into ~/.Trash. Everything else goes the usual way, never through the prompt.
public struct UninstallTrash: Trashing {
    private let appPath: String
    private let home: String
    private let base: any Trashing
    private let admin: AdminMover

    public init(appPath: String, home: String, base: any Trashing = SystemTrash(), admin: AdminMover) {
        self.appPath = appPath
        self.home = home
        self.base = base
        self.admin = admin
    }

    public func trash(_ path: String) async throws -> String {
        do {
            return try await base.trash(path)
        } catch let error where path == appPath && AdminMover.isPermissionError(error) {
            let destination = Self.freePath(in: Paths.join(home, ".Trash"), for: (path as NSString).lastPathComponent)
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            try await admin.move(path, to: destination,
                                 prompt: "Unearth needs an administrator's password to move “\(name)” to the Trash.")
            return destination
        }
    }

    public func restore(_ trashedPath: String, to originalPath: String) async throws {
        try await base.restore(trashedPath, to: originalPath)
    }

    public func deletePermanently(_ trashedPath: String) async throws {
        try await base.deletePermanently(trashedPath)
    }

    /// "Name.app", or "Name 2.app", "Name 3.app"… when the Trash already holds one.
    static func freePath(in folder: String, for name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        var candidate = Paths.join(folder, name)
        var number = 2
        while AdminMover.exists(candidate) {
            candidate = Paths.join(folder, "\(stem) \(number)" + (suffix.isEmpty ? "" : ".\(suffix)"))
            number += 1
        }
        return candidate
    }
}
