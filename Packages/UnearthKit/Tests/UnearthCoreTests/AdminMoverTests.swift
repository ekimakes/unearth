import Darwin
import Foundation
import Synchronization
import Testing
@testable import UnearthCore

/// Stands in for osascript: records each call, then moves the item, does nothing, or acts out a cancelled prompt.
final class AdminRunner: CommandRunning {
    enum Behavior { case move, nothing, cancel }

    private let behavior: Behavior
    private let calls = Mutex<[(executable: String, arguments: [String])]>([])

    init(_ behavior: Behavior) { self.behavior = behavior }

    var recorded: [(executable: String, arguments: [String])] { calls.withLock { $0 } }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> CommandResult {
        calls.withLock { $0.append((executable, arguments)) }
        switch behavior {
        case .move:
            let source = arguments[arguments.count - 3]
            let destination = arguments[arguments.count - 2]
            // An administrator can write where the user can't.
            chmod((destination as NSString).deletingLastPathComponent, 0o755)
            try FileManager.default.moveItem(atPath: source, toPath: destination)
            return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
        case .nothing:
            return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
        case .cancel:
            return CommandResult(exitCode: 1, stdout: Data(), stderr: Data("execution error: User canceled. (-128)".utf8))
        }
    }
}

/// A Trash that's never allowed to move anything, like an app owned by the system.
struct DeniedTrash: Trashing {
    func trash(_ path: String) async throws -> String { throw CocoaError(.fileWriteNoPermission) }
    func restore(_ trashedPath: String, to originalPath: String) async throws { throw CocoaError(.fileWriteNoPermission) }
    func deletePermanently(_ trashedPath: String) async throws { throw CocoaError(.fileWriteNoPermission) }
}

struct AdminMoverTests {
    struct Rig {
        let fx: Fixture
        let home: String
        let app: String
        let runner: AdminRunner
        let trash: UninstallTrash

        init(_ behavior: AdminRunner.Behavior, appName: String = "Shared.app") throws {
            fx = try Fixture()
            home = try fx.dir("home")
            try fx.dir("home/.Trash")
            app = try fx.dir("Applications/" + appName)
            try fx.file("Applications/\(appName)/Contents/Info.plist", bytes: 100)
            runner = AdminRunner(behavior)
            trash = UninstallTrash(appPath: app, home: home, base: DeniedTrash(), admin: AdminMover(runner: runner))
        }

        func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0
        }
    }

    @Test func adminRouteIsOnlyForTheAppBeingUninstalled() async throws {
        let rig = try Rig(.move)
        defer { rig.fx.remove() }
        let leftover = try rig.fx.file("home/Library/Caches/com.example.Shared/cache.db", bytes: 100)
        await #expect(throws: (any Error).self) { try await rig.trash.trash(leftover) }
        #expect(rig.runner.recorded.isEmpty)
        #expect(rig.exists(leftover))

        try rig.fx.dir("home/.Trash/Shared.app")
        let moved = try await rig.trash.trash(rig.app)
        #expect(moved == rig.home + "/.Trash/Shared 2.app")
        #expect(rig.runner.recorded.count == 1)
        #expect(!rig.exists(rig.app) && rig.exists(moved))
    }

    @Test func pathsReachTheAdminCommandOnlyAsArguments() async throws {
        let name = #"Bad"; rm -rf ~ $(x).app"#
        let rig = try Rig(.move, appName: name)
        defer { rig.fx.remove() }
        _ = try await rig.trash.trash(rig.app)
        let call = try #require(rig.runner.recorded.first)
        #expect(call.executable == "/usr/bin/osascript")
        let script = stride(from: 0, to: call.arguments.count - 3, by: 2).map { call.arguments[$0 + 1] }
        #expect(stride(from: 0, to: call.arguments.count - 3, by: 2).allSatisfy { call.arguments[$0] == "-e" })
        #expect(script == AdminMover.script)
        #expect(Array(call.arguments.suffix(3).prefix(2)) == [rig.app, rig.home + "/.Trash/" + name])
        #expect(!script.contains { $0.contains("rm -rf") })
        #expect(call.arguments.last == "Unearth needs an administrator's password to move “Bad\"; rm -rf ~ $(x)” to the Trash.")
    }

    @Test func cancellingThePasswordPromptLeavesTheApp() async throws {
        let rig = try Rig(.cancel)
        defer { rig.fx.remove() }
        await #expect(throws: AdminMoveError.cancelled) { try await rig.trash.trash(rig.app) }
        #expect(rig.exists(rig.app))
        #expect(AdminMoveError.cancelled.localizedDescription == "You cancelled the password prompt, so the app stayed where it was.")
    }

    @Test func anAdminMoveThatDidNothingIsAFailure() async throws {
        let rig = try Rig(.nothing)
        defer { rig.fx.remove() }
        await #expect(throws: AdminMoveError.failed) { try await rig.trash.trash(rig.app) }
        #expect(rig.exists(rig.app))
        #expect(AdminMoveError.failed.localizedDescription == "Unearth couldn't move this app. Drag it to the Trash in Finder.")
    }

    /// A password can't help with an app that's already the user's: macOS is what stopped the move, and it says how to
    /// allow it.
    @Test func anAppTheUserOwnsNeverAsksForAPassword() async throws {
        let rig = try Rig(.move)
        defer { rig.fx.remove() }
        let trash = UninstallTrash(appPath: rig.app, home: rig.home, base: DeniedTrash(), admin: AdminMover(runner: rig.runner),
                                   needsAdmin: false)
        await #expect(throws: AdminMoveError.blockedByMacOS) { try await trash.trash(rig.app) }
        #expect(rig.runner.recorded.isEmpty)
        #expect(rig.exists(rig.app))
        #expect(AdminMoveError.blockedByMacOS.localizedDescription
            == "macOS stopped Unearth from moving this app. Turn on Unearth in System Settings › Privacy & Security › App Management, then try again.")
    }

    @Test func undoAsksForAdminOnlyForAppsGoingBackToApplications() async throws {
        let fx = try Fixture()
        let home = try fx.dir("home")
        let applications = try fx.dir("home/Applications")
        let desktop = try fx.dir("home/Desktop")
        defer {
            chmod(applications, 0o755)
            chmod(desktop, 0o755)
            fx.remove()
        }
        let trashed = try fx.dir("home/.Trash/Shared.app")
        let note = try fx.file("home/.Trash/note.txt", bytes: 10)
        let tool = try fx.dir("home/.Trash/Tool.app")
        chmod(applications, 0o555)
        chmod(desktop, 0o555)
        let runner = AdminRunner(.move)
        let trash = SystemTrash(admin: AdminMover(runner: runner), home: home)

        try await trash.restore(trashed, to: applications + "/Shared.app")
        #expect(runner.recorded.count == 1)
        #expect(FileManager.default.fileExists(atPath: applications + "/Shared.app"))

        chmod(applications, 0o555)
        await #expect(throws: (any Error).self) { try await trash.restore(note, to: applications + "/note.txt") }
        await #expect(throws: (any Error).self) { try await trash.restore(tool, to: desktop + "/Tool.app") }
        #expect(runner.recorded.count == 1)
    }
}
