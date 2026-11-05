import Darwin
import Foundation
import Testing
@testable import UnearthCore

/// A fixture Trash that refuses one path the way a cancelled password prompt does.
struct RefusingTrash: Trashing {
    let base: FolderTrash
    let refused: String

    func trash(_ path: String) async throws -> String {
        if path == refused { throw AdminMoveError.cancelled }
        return try await base.trash(path)
    }

    func restore(_ trashedPath: String, to originalPath: String) async throws {
        try await base.restore(trashedPath, to: originalPath)
    }

    func deletePermanently(_ trashedPath: String) async throws {
        try await base.deletePermanently(trashedPath)
    }
}

struct UninstallTests {
    static let home = "/Users/me"

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    @Test func uninstallExceptionCoversOnlyThatApp() {
        let plain = SafetyGuard(homePath: Self.home, neverTouch: [])
        let exception = UninstallException(appPath: "/Applications/Foo.app",
                                           preferencesPlist: "/Users/me/Library/Preferences/com.foo.Foo.plist")
        let guarded = SafetyGuard(homePath: Self.home, neverTouch: [], uninstalling: exception)
        #expect(plain.ruleViolation(for: "/Applications/Foo.app") != nil)
        #expect(plain.ruleViolation(for: "/Users/me/Library/Preferences/com.foo.Foo.plist") != nil)
        #expect(guarded.ruleViolation(for: "/Applications/Foo.app") == nil)
        #expect(guarded.ruleViolation(for: "/Users/me/Library/Preferences/com.foo.Foo.plist") == nil)
        for refused in [
            "/Applications/Bar.app", "/Applications/Foo.app/Contents/Info.plist", "/Applications",
            "/Users/me/Library/Preferences/com.foo.FooHelper.plist", "/Users/me/Library/Preferences/com.other.plist",
            "/Users/me/Library/Preferences",
        ] {
            #expect(guarded.ruleViolation(for: refused) != nil, "\(refused)")
        }
        // An exception for anything but an app in Applications and a plist in Preferences lets nothing through.
        let odd = SafetyGuard(homePath: Self.home, neverTouch: [], uninstalling: UninstallException(
            appPath: "/System/Applications/Mail.app", preferencesPlist: "/Users/me/Library/Keychains/login.keychain-db"))
        #expect(odd.ruleViolation(for: "/System/Applications/Mail.app") != nil)
        #expect(odd.ruleViolation(for: "/Users/me/Library/Keychains/login.keychain-db") != nil)
        // The never-touch list still wins.
        let kept = SafetyGuard(homePath: Self.home, neverTouch: ["/Applications/Foo.app"], uninstalling: exception)
        #expect(kept.ruleViolation(for: "/Applications/Foo.app") == .neverTouch)
    }

    /// An app in ~/Applications with a cache and its preferences file.
    static func installed(_ fx: Fixture) throws -> (app: InstalledApp, home: String) {
        let home = try fx.dir("home")
        try AppInventoryTests.app(fx, "home/Applications/Bar.app", id: "com.foo.Bar")
        try fx.file("home/Library/Caches/com.foo.Bar/cache.db", bytes: 2_000)
        try fx.file("home/Library/Preferences/com.foo.Bar.plist", bytes: 100)
        let app = try #require(AppInventory.apps(in: [fx.path("home/Applications")], home: home, lastUsed: { _ in nil },
                                                 systemLibrary: fx.path("Library")).first)
        return (app, home)
    }

    static func engine(_ fx: Fixture, _ app: InstalledApp, home: String, running: Set<String> = [],
                       refusing refused: String? = nil) throws -> CleanupEngine {
        let folder = FolderTrash(folder: try fx.dir("trash"))
        return CleanupEngine(
            safetyGuard: SafetyGuard(homePath: home, neverTouch: [], uninstalling: Uninstall.exception(for: app, home: home)),
            trash: refused.map { RefusingTrash(base: folder, refused: $0) } ?? folder, runner: FakeCommandRunner(),
            history: CleanupHistory(fileURL: URL(fileURLWithPath: fx.path("history.json"))), dryRun: false,
            isRunning: { running.contains($0) })
    }

    @Test func appAndLeftoversGoToTheTrashWithUndo() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let (app, home) = try Self.installed(fx)
        let items = try #require(Uninstall.items(for: app))
        #expect(items.map(\.paths) == [[app.path], [fx.path("home/Library/Caches/com.foo.Bar")],
                                       [fx.path("home/Library/Preferences/com.foo.Bar.plist")]])
        #expect(items.map(\.safety) == [.review, .careful, .careful])
        #expect(items.allSatisfy { $0.owner == "com.foo.Bar" && $0.action == .trash && !$0.isSelectableByDefault })
        #expect(Uninstall.exception(for: app, home: home).preferencesPlist == fx.path("home/Library/Preferences/com.foo.Bar.plist"))

        let engine = try Self.engine(fx, app, home: home)
        let outcome = await Uninstall.perform(items, engine: engine)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.entries.count == items.count)
        let paths = items.flatMap(\.paths)
        #expect(paths.allSatisfy { !Self.exists($0) })
        #expect(await engine.undo(outcome.entries.map(\.id)).isEmpty)
        #expect(paths.allSatisfy { Self.exists($0) })
    }

    /// A cancelled password prompt, or any other failure to move the app, leaves its settings where they are:
    /// an app that stays installed must not lose them.
    @Test func leftoversStayWhenTheAppDoesNot() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let (app, home) = try Self.installed(fx)
        let items = try #require(Uninstall.items(for: app))
        let outcome = await Uninstall.perform(items, engine: try Self.engine(fx, app, home: home, refusing: app.path))
        #expect(outcome.entries.isEmpty)
        #expect(outcome.failures.map(\.reason) == [AdminMoveError.cancelled.localizedDescription])
        #expect(items.flatMap(\.paths).allSatisfy { Self.exists($0) })
    }

    @Test func runningAppsAreBlocked() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let (app, home) = try Self.installed(fx)
        let items = try #require(Uninstall.items(for: app))
        let outcome = try await Self.engine(fx, app, home: home, running: ["com.foo.Bar"]).moveToTrash(items)
        #expect(outcome.entries.isEmpty)
        #expect(outcome.failures.count == items.count)
        #expect(outcome.failures.allSatisfy { $0.reason.hasPrefix("Quit") })
        #expect(items.flatMap(\.paths).allSatisfy { Self.exists($0) })
    }

    @Test func vendorAndAppleAppsHaveNoUninstall() {
        func app(id: String, vendor: String?) -> InstalledApp {
            InstalledApp(path: "/Applications/X.app", name: "X", bundleID: id, bytes: 1, lastUsed: nil, vendorFolder: vendor,
                         isApple: id.hasPrefix("com.apple."), needsAdmin: false, leftovers: [])
        }
        #expect(Uninstall.items(for: app(id: "com.apple.Pages", vendor: nil)) == nil)
        #expect(Uninstall.items(for: app(id: "net.maxon.cinema4d", vendor: "Maxon Cinema 4D 2026")) == nil)
        #expect(Uninstall.items(for: app(id: "com.example.X", vendor: nil))?.count == 1)
    }
}
