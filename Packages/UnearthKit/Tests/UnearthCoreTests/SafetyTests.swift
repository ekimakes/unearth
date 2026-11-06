import Darwin
import Foundation
import Synchronization
import Testing
@testable import UnearthCore

struct SafetyGuardTests {
    static let home = "/Users/u"
    let safety = SafetyGuard(homePath: Self.home, neverTouch: ["/Users/u/Projects/keep"])

    @Test func refusesEssentialFolders() {
        for path in [
            "/Users/u", "/Users/u/Desktop", "/Users/u/Documents", "/Users/u/Downloads", "/Users/u/Pictures",
            "/Users/u/Movies", "/Users/u/Music", "/Users/u/Library", "/Users/u/Public", "/Users/u/Applications",
            "/Users/u/Library/Application Support", "/Users/u/Library/Caches", "/Users/u/Library/Containers",
            "/Users/u/Library/Group Containers", "/Users/u/.Trash", "/Users/Shared", "/Volumes/External",
        ] {
            #expect(throws: SafetyViolation.essentialFolder, "\(path)") { try safety.check(path) }
        }
    }

    @Test func refusesInsideProtected() {
        for path in [
            "/Users/u/Library/Keychains/login.keychain-db", "/Users/u/Library/Mail/V10/x", "/Users/u/Library/Messages/chat.db",
            "/Users/u/Library/Mobile Documents/com~apple~CloudDocs/x", "/Users/u/Library/Preferences/com.x.plist",
            "/Users/u/Pictures/Photos Library.photoslibrary/database", "/Users/u/Library/Preferences",
        ] {
            #expect(throws: SafetyViolation.protectedLocation, "\(path)") { try safety.check(path) }
        }
    }

    @Test func refusesOutsideRoots() {
        for path in ["/System/Library/x", "/Library/Caches/x", "/Applications/Safari.app", "/private/etc/hosts", "/Users/other/x"] {
            #expect(throws: SafetyViolation.outsideAllowedRoots, "\(path)") { try safety.check(path) }
        }
    }

    @Test func refusesNeverTouchInsideAndContaining() {
        #expect(throws: SafetyViolation.neverTouch) { try safety.check("/Users/u/Projects/keep/build") }
        #expect(throws: SafetyViolation.neverTouch) { try safety.check("/Users/u/Projects/keep") }
        #expect(throws: SafetyViolation.neverTouch) { try safety.check("/Users/u/Projects") }
    }

    @Test func refusesRelativeAndDotDotPaths() {
        #expect(throws: SafetyViolation.notAbsolute) { try safety.check("Library/Caches/x") }
        #expect(throws: SafetyViolation.notAbsolute) { try safety.check("/Users/u/Library/Caches/../../Documents") }
    }

    @Test func refusesSymlinkedParent() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("home/real/data.bin", bytes: 10)
        try fx.symlink("home/link", to: fx.path("home/real"))
        let guardian = SafetyGuard(homePath: fx.path("home"), neverTouch: [])
        #expect(throws: SafetyViolation.symlinkedParent) { try guardian.check(fx.path("home/link/data.bin")) }
        #expect(throws: Never.self) { try guardian.check(fx.path("home/link")) }
    }

    @Test func allowsCacheFolderInsideHome() {
        #expect(throws: Never.self) { try safety.check("/Users/u/Library/Caches/com.foo") }
        #expect(throws: Never.self) { try safety.check("/Users/u/Library/Developer/Xcode/DerivedData/App-abc") }
        #expect(throws: Never.self) { try safety.check("/Volumes/External/old.dmg") }
    }
}

struct ToolAllowlistTests {
    @Test func acceptsTheFourTemplates() {
        #expect(ToolAllowlist.validate(ToolCommand(toolName: "Xcode", executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"])))
        #expect(ToolAllowlist.validate(ToolCommand(toolName: "Xcode", executable: "/usr/bin/xcrun",
                                                   arguments: ["simctl", "runtime", "delete", "11111111-1111-4111-8111-111111111111"])))
        #expect(ToolAllowlist.validate(SnapshotDetector.deleteCommand))
        #expect(ToolAllowlist.validate(ToolCommand(toolName: "Homebrew", executable: "/opt/homebrew/bin/brew", arguments: ["cleanup", "--prune=all"])))
        #expect(ToolAllowlist.validate(ToolCommand(toolName: "Homebrew", executable: "/usr/local/bin/brew", arguments: ["cleanup", "--prune=all"])))
    }

    @Test func rejectsAnythingElse() {
        #expect(!ToolAllowlist.validate(ToolCommand(toolName: "Xcode", executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable", "--all"])))
        #expect(!ToolAllowlist.validate(ToolCommand(toolName: "Xcode", executable: "/bin/rm", arguments: ["-rf", "/"])))
        #expect(!ToolAllowlist.validate(ToolCommand(toolName: "Xcode", executable: "/usr/bin/xcrun", arguments: ["simctl", "runtime", "delete", "x; rm -rf ~"])))
        #expect(!ToolAllowlist.validate(ToolCommand(toolName: "Time Machine", executable: "/usr/bin/tmutil", arguments: ["deletelocalsnapshots", "/"], needsAdmin: false)))
        #expect(!ToolAllowlist.validate(ToolCommand(toolName: "Homebrew", executable: "/tmp/brew", arguments: ["cleanup", "--prune=all"])))
    }
}

struct CleanupHistoryTests {
    static func entry(_ title: String, trashPath: String? = nil) -> HistoryEntry {
        HistoryEntry(kind: .trashed, title: title, originalPath: "/Users/u/\(title)", trashPath: trashPath,
                     trashFileID: 7, bytes: 42, commandLine: nil, state: .inTrash)
    }

    @Test func persistsAndReloads() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let url = URL(fileURLWithPath: fx.path("support/history.json"))
        let first = CleanupHistory(fileURL: url)
        try await first.record([Self.entry("a")])
        try await first.record([Self.entry("b")])
        let reloaded = await CleanupHistory(fileURL: url).all()
        #expect(reloaded.map(\.title) == ["b", "a"])
        #expect(reloaded == (await first.all()))
    }

    @Test func loadingDropsWhatADryRunLeftBehind() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let url = URL(fileURLWithPath: fx.path("history.json"))
        let neverMoved = HistoryEntry(kind: .trashed, title: "never moved", originalPath: "/Users/u/a", trashPath: nil,
                                      trashFileID: nil, bytes: 42, commandLine: nil, state: .completed)
        let toolRun = HistoryEntry(kind: .toolRun, title: "tool", originalPath: nil, trashPath: nil, trashFileID: nil,
                                   bytes: 42, commandLine: "xcrun", state: .completed)
        try await CleanupHistory(fileURL: url).record([neverMoved, Self.entry("moved", trashPath: "/trash/moved"), toolRun])
        #expect(await CleanupHistory(fileURL: url).all().map(\.title) == ["moved", "tool"])
    }

    @Test func reconcileMarksGoneFromTrash() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let history = CleanupHistory(fileURL: URL(fileURLWithPath: fx.path("history.json")))
        try await history.record([Self.entry("kept", trashPath: "/trash/kept"), Self.entry("gone", trashPath: "/trash/gone")])
        try await history.reconcile { $0 == "/trash/kept" }
        let states = Dictionary(uniqueKeysWithValues: await history.all().map { ($0.title, $0.state) })
        #expect(states == ["kept": .inTrash, "gone": .goneFromTrash])
    }
}

struct CleanupEngineTests {
    /// A home, a fake Trash, a fake runner and an engine wired together.
    struct Rig {
        let fx: Fixture
        let home: String
        let trash: FolderTrash
        let runner: FakeCommandRunner
        let history: CleanupHistory
        let engine: CleanupEngine

        init(running: Set<String> = [], dryRun: Bool = false, neverTouch: [String] = [],
             responses: [String: CommandResult] = [:]) throws {
            let fixture = try Fixture()
            let homePath = try fixture.dir("home")
            let folderTrash = FolderTrash(folder: try fixture.dir("trash"))
            let fakeRunner = FakeCommandRunner(responses)
            let cleanupHistory = CleanupHistory(fileURL: URL(fileURLWithPath: fixture.path("history.json")))
            let protected = neverTouch.map { fixture.path("home/" + $0) }
            fx = fixture
            home = homePath
            trash = folderTrash
            runner = fakeRunner
            history = cleanupHistory
            engine = CleanupEngine(
                safetyGuard: SafetyGuard(homePath: homePath, neverTouch: protected),
                trash: folderTrash, runner: fakeRunner, history: cleanupHistory, dryRun: dryRun,
                isRunning: { running.contains($0) })
        }

        func item(_ relative: String, owner: String? = nil, action: CleanupAction = .trash) -> CleanupItem {
            CleanupItem(ruleID: "t", section: .junk, group: "g", title: relative, subtitle: nil, paths: [home + "/" + relative],
                        bytes: 4_096, safety: .safe, action: action,
                        explanation: Explanation(what: "w", regrows: "r", safeToDelete: "s"), owner: owner, blockedReason: nil)
        }

        func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0
        }
    }

    static func tool(_ command: ToolCommand) -> CleanupItem {
        CleanupItem(ruleID: "tool", section: .developer, group: "g", title: command.toolName, subtitle: nil, paths: [],
                    bytes: 0, safety: .safe, action: .tool(command),
                    explanation: Explanation(what: "w", regrows: "r", safeToDelete: "s"), owner: nil, blockedReason: nil)
    }

    @Test func movesItemsAndRecordsHistory() async throws {
        let rig = try Rig()
        defer { rig.fx.remove() }
        try rig.fx.file("home/Library/Caches/com.foo/blob", bytes: 4_000)
        let outcome = await rig.engine.moveToTrash([rig.item("Library/Caches/com.foo")])
        #expect(outcome.failures.isEmpty)
        #expect(!rig.exists(rig.home + "/Library/Caches/com.foo"))
        let entry = try #require(outcome.entries.first)
        #expect(entry.state == .inTrash)
        #expect(rig.exists(try #require(entry.trashPath)))
        #expect(outcome.bytesMovedToTrash == 4_096)
        #expect(await rig.history.all() == outcome.entries)
    }

    @Test func reportsItemsThatVanishedSinceScan() async throws {
        let rig = try Rig()
        defer { rig.fx.remove() }
        let outcome = await rig.engine.moveToTrash([rig.item("Library/Caches/gone")])
        #expect(outcome.entries.isEmpty)
        #expect(outcome.failures.map(\.reason) == ["Already gone"])
    }

    @Test func trashesSymlinkNotTarget() async throws {
        let rig = try Rig()
        defer { rig.fx.remove() }
        let target = try rig.fx.file("home/real/precious.txt", bytes: 100)
        try rig.fx.symlink("home/Library-link", to: rig.home + "/real")
        let outcome = await rig.engine.moveToTrash([rig.item("Library-link")])
        #expect(outcome.failures.isEmpty)
        #expect(!rig.exists(rig.home + "/Library-link"))
        #expect(rig.exists(target))
    }

    @Test func skipsItemWhoseAppStartedRunning() async throws {
        let rig = try Rig(running: ["com.foo"])
        defer { rig.fx.remove() }
        try rig.fx.file("home/Library/Caches/com.foo/blob", bytes: 4_000)
        let outcome = await rig.engine.moveToTrash([rig.item("Library/Caches/com.foo", owner: "com.foo")])
        #expect(outcome.entries.isEmpty)
        #expect(outcome.failures.first?.reason.hasPrefix("Quit") == true)
        #expect(rig.exists(rig.home + "/Library/Caches/com.foo"))
    }

    @Test func refusesGuardViolationsWithoutTouchingDisk() async throws {
        let rig = try Rig(neverTouch: ["Projects/keep"])
        defer { rig.fx.remove() }
        try rig.fx.file("home/Documents/thesis.pdf", bytes: 100)
        try rig.fx.file("home/Projects/keep/a.txt", bytes: 100)
        let outcome = await rig.engine.moveToTrash([rig.item("Documents"), rig.item("Projects/keep")])
        #expect(outcome.entries.isEmpty)
        #expect(outcome.failures.count == 2)
        #expect(rig.exists(rig.home + "/Documents/thesis.pdf"))
        #expect(rig.exists(rig.home + "/Projects/keep/a.txt"))
    }

    @Test func undoRestoresToOriginalPath() async throws {
        let rig = try Rig()
        defer { rig.fx.remove() }
        try rig.fx.file("home/Library/Caches/com.foo/blob", bytes: 4_000)
        let outcome = await rig.engine.moveToTrash([rig.item("Library/Caches/com.foo")])
        let failures = await rig.engine.undo(outcome.entries.map(\.id))
        #expect(failures.isEmpty)
        #expect(rig.exists(rig.home + "/Library/Caches/com.foo/blob"))
        #expect(await rig.history.all().first?.state == .restored)
    }

    @Test func undoRefusesToOverwriteRecreatedFolder() async throws {
        let rig = try Rig()
        defer { rig.fx.remove() }
        try rig.fx.file("home/Library/Caches/com.foo/old", bytes: 4_000)
        let outcome = await rig.engine.moveToTrash([rig.item("Library/Caches/com.foo")])
        try rig.fx.file("home/Library/Caches/com.foo/new", bytes: 10)
        let failures = await rig.engine.undo(outcome.entries.map(\.id))
        #expect(failures.first?.reason == "Something new is at the original location, so it was left in the Trash.")
        #expect(rig.exists(rig.home + "/Library/Caches/com.foo/new"))
        #expect(rig.exists(try #require(outcome.entries.first?.trashPath)))
        #expect(await rig.history.all().first?.state == .inTrash)
    }

    @Test func deletePermanentlyOnlyTouchesRecordedTrashItems() async throws {
        let rig = try Rig()
        defer { rig.fx.remove() }
        try rig.fx.file("home/Library/Caches/com.foo/blob", bytes: 4_000)
        let unrelated = try rig.fx.file("trash/someone-elses-file.txt", bytes: 10)
        let outcome = await rig.engine.moveToTrash([rig.item("Library/Caches/com.foo")])
        let failures = await rig.engine.deletePermanently(outcome.entries.map(\.id))
        #expect(failures.isEmpty)
        #expect(!rig.exists(try #require(outcome.entries.first?.trashPath)))
        #expect(rig.exists(unrelated))
        #expect(await rig.history.all().first?.state == .deletedPermanently)
    }

    @Test func deletePermanentlyRefusesReplacedTrashItem() async throws {
        let rig = try Rig()
        defer { rig.fx.remove() }
        try rig.fx.file("home/Library/Caches/com.foo/blob", bytes: 4_000)
        let outcome = await rig.engine.moveToTrash([rig.item("Library/Caches/com.foo")])
        let trashPath = try #require(outcome.entries.first?.trashPath)
        try FileManager.default.removeItem(atPath: trashPath)
        FileManager.default.createFile(atPath: trashPath, contents: Data("new".utf8))
        let failures = await rig.engine.deletePermanently(outcome.entries.map(\.id))
        #expect(failures.count == 1)
        #expect(rig.exists(trashPath))
    }

    @Test func runToolUsesExactArguments() async throws {
        let rig = try Rig(responses: ["/usr/bin/xcrun simctl delete unavailable": .success("")])
        defer { rig.fx.remove() }
        let command = ToolCommand(toolName: "Xcode", executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"])
        let outcome = await rig.engine.runTool(Self.tool(command))
        #expect(outcome.failures.isEmpty)
        #expect(rig.runner.calls.map(\.arguments) == [["simctl", "delete", "unavailable"]])
        #expect(outcome.entries.first?.kind == .toolRun)
        #expect(outcome.entries.first?.state == .completed)
        #expect(outcome.entries.first?.commandLine == "/usr/bin/xcrun simctl delete unavailable")
    }

    @Test func runToolWrapsAdminCommandsInOsascript() async throws {
        let script = "do shell script \"/usr/bin/tmutil deletelocalsnapshots /\" with administrator privileges"
        let rig = try Rig(responses: ["/usr/bin/osascript -e \(script)": .success("")])
        defer { rig.fx.remove() }
        let outcome = await rig.engine.runTool(Self.tool(SnapshotDetector.deleteCommand))
        #expect(outcome.failures.isEmpty)
        #expect(rig.runner.calls.first?.executable == "/usr/bin/osascript")
        #expect(rig.runner.calls.first?.arguments == ["-e", script])
    }

    @Test func runToolRejectsUnlistedCommands() async throws {
        let rig = try Rig()
        defer { rig.fx.remove() }
        let outcome = await rig.engine.runTool(Self.tool(ToolCommand(toolName: "Evil", executable: "/bin/rm", arguments: ["-rf", "/"])))
        #expect(outcome.failures.count == 1)
        #expect(rig.runner.calls.isEmpty)
    }

    @Test func runToolReportsFailedCommands() async throws {
        let rig = try Rig(responses: ["/usr/bin/xcrun simctl delete unavailable": CommandResult(
            exitCode: 1, stdout: Data(), stderr: Data("simctl broke\n".utf8))])
        defer { rig.fx.remove() }
        let command = ToolCommand(toolName: "Xcode", executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"])
        let outcome = await rig.engine.runTool(Self.tool(command))
        #expect(outcome.failures.first?.reason == "simctl broke")
        #expect(outcome.entries.first?.state == .failed)
    }

    @Test func dryRunMovesNothing() async throws {
        let rig = try Rig(dryRun: true)
        defer { rig.fx.remove() }
        try rig.fx.file("home/Library/Caches/com.foo/blob", bytes: 4_000)
        let outcome = await rig.engine.moveToTrash([rig.item("Library/Caches/com.foo")])
        #expect(rig.exists(rig.home + "/Library/Caches/com.foo/blob"))
        #expect(outcome.entries.first?.state == .completed)
        #expect(outcome.bytesMovedToTrash == 4_096)
        let command = ToolCommand(toolName: "Xcode", executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"])
        _ = await rig.engine.runTool(Self.tool(command))
        #expect(rig.runner.calls.isEmpty)
    }

    @Test func undoingABigMoveDoesNotCrawl() async throws {
        let rig = try Rig()
        defer { rig.fx.remove() }
        let names = (0..<2_000).map { "Library/Caches/file\($0)" }
        for name in names { try rig.fx.file("home/" + name, bytes: 10) }
        let outcome = await rig.engine.moveToTrash(names.map { rig.item($0) })
        let began = ContinuousClock.now
        let failures = await rig.engine.undo(outcome.entries.map(\.id))
        #expect(failures.isEmpty)
        #expect(ContinuousClock.now - began < .seconds(6))
        #expect(await rig.history.all().allSatisfy { $0.state == .restored })
        #expect(names.allSatisfy { rig.exists(rig.home + "/" + $0) })
    }

    @Test func deletingABigMoveDoesNotCrawl() async throws {
        let rig = try Rig()
        defer { rig.fx.remove() }
        let names = (0..<2_000).map { "Library/Caches/file\($0)" }
        for name in names { try rig.fx.file("home/" + name, bytes: 10) }
        let outcome = await rig.engine.moveToTrash(names.map { rig.item($0) })
        let began = ContinuousClock.now
        let failures = await rig.engine.deletePermanently(outcome.entries.map(\.id))
        #expect(failures.isEmpty)
        #expect(ContinuousClock.now - began < .seconds(6))
        #expect(await rig.history.all().allSatisfy { $0.state == .deletedPermanently })
    }

    @Test func undoRecordsAnItemThatLeftTheTrash() async throws {
        let rig = try Rig()
        defer { rig.fx.remove() }
        try rig.fx.file("home/Library/Caches/com.foo/blob", bytes: 4_000)
        let outcome = await rig.engine.moveToTrash([rig.item("Library/Caches/com.foo")])
        let entry = try #require(outcome.entries.first)
        try FileManager.default.removeItem(atPath: try #require(entry.trashPath))
        let failures = await rig.engine.undo([entry.id])
        #expect(failures.first?.reason == "It's no longer in the Trash.")
        #expect(await rig.history.all().first?.state == .goneFromTrash)
    }

    @Test func aDryRunLeavesNoHistory() async throws {
        let rig = try Rig(dryRun: true)
        defer { rig.fx.remove() }
        try rig.fx.file("home/Library/Caches/com.foo/blob", bytes: 4_000)
        _ = await rig.engine.moveToTrash([rig.item("Library/Caches/com.foo")])
        #expect(await rig.history.all().isEmpty)
    }

    @Test func progressCountsEveryItem() async throws {
        let rig = try Rig()
        defer { rig.fx.remove() }
        try rig.fx.file("home/Library/Caches/com.foo/blob", bytes: 4_000)
        try rig.fx.file("home/Library/Caches/com.bar/blob", bytes: 4_000)
        let seen = Mutex<[Int]>([])
        _ = await rig.engine.moveToTrash([rig.item("Library/Caches/com.foo"), rig.item("Library/Caches/com.bar")]) { done in
            seen.withLock { $0.append(done) }
        }
        #expect(seen.withLock { $0 } == [1, 2])
    }

    @Test func deletingCountsEveryItem() async throws {
        let rig = try Rig()
        defer { rig.fx.remove() }
        try rig.fx.file("home/Library/Caches/com.foo/blob", bytes: 4_000)
        try rig.fx.file("home/Library/Caches/com.bar/blob", bytes: 4_000)
        let outcome = await rig.engine.moveToTrash([rig.item("Library/Caches/com.foo"), rig.item("Library/Caches/com.bar")])
        let seen = Mutex<[Int]>([])
        _ = await rig.engine.deletePermanently(outcome.entries.map(\.id)) { done in
            seen.withLock { $0.append(done) }
        }
        #expect(seen.withLock { $0 } == [1, 2])
    }

    @Test func deletingCountsWhatItRefuses() async throws {
        let rig = try Rig()
        defer { rig.fx.remove() }
        let seen = Mutex<[Int]>([])
        let failures = await rig.engine.deletePermanently([UUID()]) { done in
            seen.withLock { $0.append(done) }
        }
        #expect(failures.count == 1)
        #expect(seen.withLock { $0 } == [1])
    }
}
