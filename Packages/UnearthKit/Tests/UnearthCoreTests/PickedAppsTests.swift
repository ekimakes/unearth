import Foundation
import Synchronization
import Testing
@testable import UnearthCore

/// Removing an app by hand, from the Apps page or the Disk Map.
struct PickedAppsTests {
    /// The engine everything else goes through. Like the Safety Guard with anything in /Applications, it refuses the app.
    static func ordinary(_ fx: Fixture, home: String, refusing path: String) throws -> CleanupEngine {
        CleanupEngine(
            safetyGuard: SafetyGuard(homePath: home, neverTouch: [path]), trash: FolderTrash(folder: try fx.dir("trash")),
            runner: FakeCommandRunner(), history: CleanupHistory(fileURL: URL(fileURLWithPath: fx.path("ordinary.json"))),
            dryRun: false, isRunning: { _ in false })
    }

    static func picked(_ path: String) -> CleanupItem {
        .picked(path: path, bytes: 100, what: "A file you picked in your Library.")
    }

    /// An app picked on the Apps page used to come back as "Nothing was moved".
    @Test func anAppPickedByHandGoesToTheTrash() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let (app, home) = try UninstallTests.installed(fx)
        let engine = try UninstallTests.engine(fx, app, home: home)
        let outcome = await PickedApps.moveToTrash(
            [Self.picked(app.path)], apps: [app.path: app], isRunning: { _ in false },
            engine: try Self.ordinary(fx, home: home, refusing: app.path), appEngine: { _ in engine })
        #expect(outcome.failures.isEmpty)
        #expect(outcome.entries.map(\.originalPath) == [app.path])
        #expect(!UninstallTests.exists(app.path))
        #expect(await engine.undo(outcome.entries.map(\.id)).isEmpty)
        #expect(UninstallTests.exists(app.path))
    }

    /// The confirmation names only the app, so nothing else moves with it.
    @Test func onlyTheAppMoves() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let (app, home) = try UninstallTests.installed(fx)
        let outcome = await PickedApps.moveToTrash(
            [Self.picked(app.path)], apps: [app.path: app], isRunning: { _ in false },
            engine: try Self.ordinary(fx, home: home, refusing: app.path),
            appEngine: { [engine = try! UninstallTests.engine(fx, app, home: home)] _ in engine })
        #expect(outcome.entries.count == 1)
        #expect(UninstallTests.exists(fx.path("home/Library/Caches/com.foo.Bar")))
        #expect(UninstallTests.exists(fx.path("home/Library/Preferences/com.foo.Bar.plist")))
    }

    @Test func whatElseWasPickedGoesTheUsualWay() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let (app, home) = try UninstallTests.installed(fx)
        let note = try fx.file("home/Documents/note.txt", bytes: 10)
        let heard = Mutex<[Int]>([])
        let outcome = await PickedApps.moveToTrash(
            [Self.picked(note), Self.picked(app.path)], apps: [app.path: app], isRunning: { _ in false },
            engine: try Self.ordinary(fx, home: home, refusing: app.path),
            appEngine: { [engine = try! UninstallTests.engine(fx, app, home: home)] _ in engine },
            progress: { done in heard.withLock { $0.append(done) } })
        #expect(outcome.failures.isEmpty)
        #expect(Set(outcome.entries.compactMap(\.originalPath)) == [note, app.path])
        #expect(heard.withLock { $0 } == [1, 2])
    }

    @Test func anOpenAppStaysAndSaysSo() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let (app, home) = try UninstallTests.installed(fx)
        let outcome = await PickedApps.moveToTrash(
            [Self.picked(app.path)], apps: [app.path: app], isRunning: { $0 == "com.foo.Bar" },
            engine: try Self.ordinary(fx, home: home, refusing: app.path),
            appEngine: { [engine = try! UninstallTests.engine(fx, app, home: home)] _ in engine })
        #expect(outcome.entries.isEmpty)
        #expect(outcome.failures.map(\.reason) == ["Quit Bar first, then try again."])
        #expect(UninstallTests.exists(app.path))
    }

    @Test func appsUnearthLeavesAloneStayAndSayWhy() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let (app, home) = try UninstallTests.installed(fx)
        func copy(id: String, vendor: String?) -> InstalledApp {
            InstalledApp(path: app.path, name: "Bar", bundleID: id, bytes: 1, lastUsed: nil, vendorFolder: vendor,
                         isApple: id.hasPrefix("com.apple."), needsAdmin: false, leftovers: [])
        }
        for (held, reason) in [
            (copy(id: "com.apple.Pages", vendor: nil), "It's one of Apple's own apps, so Unearth leaves it alone."),
            (copy(id: "net.maxon.c4d", vendor: "Maxon 2026"), "Use Maxon 2026's uninstaller. It also removes what it installed elsewhere."),
        ] {
            let outcome = await PickedApps.moveToTrash(
                [Self.picked(app.path)], apps: [app.path: held], isRunning: { _ in false },
                engine: try Self.ordinary(fx, home: home, refusing: app.path),
                appEngine: { [engine = try! UninstallTests.engine(fx, app, home: home)] _ in engine })
            #expect(outcome.entries.isEmpty)
            #expect(outcome.failures.map(\.reason) == [reason])
            #expect(UninstallTests.exists(app.path))
        }
    }

    @Test func onlyPickedAppBundlesAreLookedUp() {
        func item(rule: String, path: String) -> CleanupItem {
            CleanupItem(ruleID: rule, section: .manual, group: "x", title: "x", subtitle: nil, paths: [path], bytes: 1,
                        safety: .review, action: .trash, explanation: CollectionKind.unusedApps.explanation, owner: nil,
                        blockedReason: nil)
        }
        let paths = PickedApps.candidates(in: [
            Self.picked("/Applications/Foo.app"), Self.picked("/Applications/BAR.APP"), Self.picked("/Users/me/note.txt"),
            item(rule: "collection-largeFiles", path: "/Applications/Big.app"), item(rule: "some-rule", path: "/Applications/Rule.app"),
        ])
        #expect(paths == ["/Applications/Foo.app", "/Applications/BAR.APP", "/Applications/Big.app"])
    }

    @Test func findsAnAppOnlyWhereAppsLive() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let plain = try AppInventoryTests.app(fx, "Applications/Plain.app", id: "com.example.Plain")
        let vendored = try AppInventoryTests.app(fx, "Applications/Maxon 2026/Demo.app", id: "net.maxon.demo")
        let utility = try AppInventoryTests.app(fx, "Applications/Utilities/Tool.app", id: "com.example.Tool")
        let elsewhere = try AppInventoryTests.app(fx, "home/Downloads/Copy.app", id: "com.example.Copy")
        let inner = try AppInventoryTests.app(fx, "Applications/Plain.app/Contents/Helpers/Helper.app", id: "com.example.Helper")
        let find: (String) -> InstalledApp? = {
            AppInventory.app(at: $0, in: [fx.path("Applications")], home: fx.path("home"), systemLibrary: fx.path("Library"))
        }
        #expect(find(plain)?.bundleID == "com.example.Plain")
        #expect(find(plain)?.name == "Plain")
        #expect(find(plain)?.vendorFolder == nil)
        #expect(find(vendored)?.vendorFolder == "Maxon 2026")
        #expect(find(utility)?.vendorFolder == nil)
        for nothing in [elsewhere, inner, fx.path("Applications/Missing.app"), fx.path("Applications/Maxon 2026")] {
            #expect(find(nothing) == nil, "\(nothing)")
        }
    }
}
