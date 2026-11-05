import Foundation

public protocol Trashing: Sendable {
    /// Moves the item (a link itself, never its target) to the Trash and returns where it went.
    /// Async, so a password prompt for an app installed for all users never blocks a thread.
    func trash(_ path: String) async throws -> String
    func restore(_ trashedPath: String, to originalPath: String) async throws
    /// Must refuse anything that isn't inside a Trash folder.
    func deletePermanently(_ trashedPath: String) async throws
}

public enum TrashError: Error {
    case notInTrash
}

/// The real Trash: the user's, or the volume's on external drives.
public struct SystemTrash: Trashing {
    private let admin: AdminMover?
    private let home: String

    /// With an `admin` mover, an app that was moved to the Trash with an administrator's password can be put
    /// back in /Applications or ~/Applications the same way.
    public init(admin: AdminMover? = nil, home: String = NSHomeDirectory()) {
        self.admin = admin
        self.home = home
    }

    public func trash(_ path: String) async throws -> String {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return (resulting as URL?)?.path ?? path
    }

    public func restore(_ trashedPath: String, to originalPath: String) async throws {
        do {
            try FileManager.default.moveItem(atPath: trashedPath, toPath: originalPath)
        } catch let error where AdminMover.isPermissionError(error) {
            let folder = (originalPath as NSString).deletingLastPathComponent
            let isApp = originalPath.lowercased().hasSuffix(".app")
                && ["/Applications", Paths.join(home, "Applications")].contains { Self.isSame(folder, $0) }
            guard let admin, isApp else { throw error }
            let name = ((originalPath as NSString).lastPathComponent as NSString).deletingPathExtension
            try await admin.move(trashedPath, to: originalPath,
                                 prompt: "Unearth needs an administrator's password to put “\(name)” back in Applications.")
        }
    }

    private static func isSame(_ a: String, _ b: String) -> Bool {
        Paths.isSameOrInside(a, b) && Paths.isSameOrInside(b, a)
    }

    public func deletePermanently(_ trashedPath: String) async throws {
        let parts = trashedPath.split(separator: "/")
        guard parts.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) else { throw TrashError.notInTrash }
        try FileManager.default.removeItem(atPath: trashedPath)
    }
}
