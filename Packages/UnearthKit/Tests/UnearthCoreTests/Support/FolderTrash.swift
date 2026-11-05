import Darwin
import Foundation
@testable import UnearthCore

/// A stand-in Trash inside a fixture, so tests never touch the user's real Trash.
struct FolderTrash: Trashing {
    let folder: String

    func trash(_ path: String) async throws -> String {
        let destination = folder + "/" + UUID().uuidString.prefix(8) + "-" + (path as NSString).lastPathComponent
        // rename(2) moves a symlink itself, never its target.
        guard rename(path, destination) == 0 else { throw Fixture.posixError() }
        return destination
    }

    func restore(_ trashedPath: String, to originalPath: String) async throws {
        try FileManager.default.moveItem(atPath: trashedPath, toPath: originalPath)
    }

    func deletePermanently(_ trashedPath: String) async throws {
        guard trashedPath != folder, Paths.isSameOrInside(trashedPath, folder) else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(atPath: trashedPath)
    }
}
