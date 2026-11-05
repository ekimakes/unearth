import Darwin
import Foundation
import Testing
@testable import UnearthCore

struct AppInventoryTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    /// An app bundle with an Info.plist (no bundle id when `id` is nil).
    @discardableResult
    static func app(_ fx: Fixture, _ relative: String, id: String?, bytes: Int = 50_000) throws -> String {
        try fx.file(relative + "/Contents/MacOS/binary", bytes: bytes)
        var info: [String: Any] = ["CFBundleName": "x"]
        if let id { info["CFBundleIdentifier"] = id }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: fx.path(relative + "/Contents/Info.plist")))
        return fx.path(relative)
    }

    static func inventory(_ fx: Fixture, lastUsed: [String: Double] = [:]) -> [InstalledApp] {
        let opened = lastUsed.mapValues(daysAgo)
        return AppInventory.apps(in: [fx.path("Applications")], home: fx.path("home"),
                                 lastUsed: { opened[($0 as NSString).lastPathComponent] },
                                 systemLibrary: fx.path("Library"))
    }

    @Test func readsAppsWithBundleIDsAndSizes() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let notes = try Self.app(fx, "Applications/Notes Pro.app", id: "com.example.NotesPro", bytes: 300_000)
        try Self.app(fx, "Applications/Broken.app", id: nil)
        try fx.file("Applications/readme.txt", bytes: 10)
        let apps = Self.inventory(fx, lastUsed: ["Notes Pro.app": 12])
        #expect(apps.count == 1)
        let app = try #require(apps.first)
        #expect(app.path == notes)
        #expect(app.name == "Notes Pro")
        #expect(app.bundleID == "com.example.NotesPro")
        #expect(app.bytes >= 300_000)
        #expect(app.lastUsed == Self.daysAgo(12))
        #expect(!app.isApple && app.vendorFolder == nil && !app.needsAdmin)
        #expect(app.leftovers.isEmpty && app.movableBytes == app.bytes)
    }

    @Test func leftoversMatchOnlyTheExactBundleID() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try Self.app(fx, "Applications/Bar.app", id: "com.foo.Bar")
        let library = "home/Library/"
        let theirs = [
            "Application Support/com.foo.Bar/data.db", "Caches/com.foo.Bar/cache.bin", "Containers/com.foo.Bar/x",
            "Group Containers/TEAM123.com.foo.Bar/shared.db", "Saved Application State/com.foo.Bar.savedState/window",
            "Logs/com.foo.Bar/log.txt", "HTTPStorages/com.foo.Bar/cookies", "WebKit/com.foo.Bar/store",
            "Application Scripts/com.foo.Bar/script", "Preferences/com.foo.Bar.plist",
        ]
        let others = [
            "Application Support/com.foo.BarHelper/data.db", "Caches/com.foo.Bar2/cache.bin",
            "Group Containers/TEAM123.com.foo.Bar2/shared.db", "Preferences/com.foo.BarHelper.plist",
            "Preferences/com.foo.Bar2.plist",
        ]
        for path in theirs + others { try fx.file(library + path, bytes: 1_000) }
        let app = try #require(Self.inventory(fx).first)
        // Each leftover is the app's own folder or file, not what's inside it.
        let expected = Set(theirs.map { fx.path(library + $0.split(separator: "/").prefix(2).joined(separator: "/")) })
        #expect(Set(app.leftovers.map(\.path)) == expected)
        #expect(app.leftovers.allSatisfy { $0.movable })
        #expect(app.movableBytes >= app.bytes + 10 * 1_000)
    }

    @Test func systemWideLeftoversAreListedNotMovable() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try Self.app(fx, "Applications/Bar.app", id: "com.foo.Bar")
        try fx.file("Library/LaunchDaemons/com.foo.Bar.helper.plist", bytes: 1_000)
        try fx.file("Library/LaunchAgents/com.foo.Bar.plist", bytes: 1_000)
        try fx.file("Library/LaunchAgents/com.foo.BarHelper.plist", bytes: 1_000)
        try fx.file("Library/Application Support/com.foo.Bar/engine.bin", bytes: 5_000_000)
        try fx.file("Library/PrivilegedHelperTools/com.foo.Bar.helper", bytes: 1_000)
        let app = try #require(Self.inventory(fx).first)
        #expect(Set(app.leftovers.map(\.path)) == [
            fx.path("Library/LaunchDaemons/com.foo.Bar.helper.plist"), fx.path("Library/LaunchAgents/com.foo.Bar.plist"),
            fx.path("Library/Application Support/com.foo.Bar"), fx.path("Library/PrivilegedHelperTools/com.foo.Bar.helper"),
        ])
        #expect(app.leftovers.allSatisfy { !$0.movable })
        #expect(app.movableBytes == app.bytes)
    }

    @Test func appleAppsAreNeverOffered() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try Self.app(fx, "Applications/Keynote.app", id: "com.apple.iWork.Keynote")
        let apps = Self.inventory(fx, lastUsed: ["Keynote.app": 400])
        #expect(apps.first?.isApple == true)
        #expect(AppInventory.unused(apps, now: Self.now, days: 90).isEmpty)
    }

    @Test func vendorFolderAppsGetGuidance() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try Self.app(fx, "Applications/Maxon Cinema 4D 2026/Cinema 4D.app", id: "net.maxon.cinema4d")
        try Self.app(fx, "Applications/Utilities/Tool.app", id: "com.example.Tool")
        let apps = Self.inventory(fx)
        #expect(apps.first { $0.name == "Cinema 4D" }?.vendorFolder == "Maxon Cinema 4D 2026")
        let tool = try #require(apps.first { $0.name == "Tool" })
        #expect(tool.vendorFolder == nil)
    }

    @Test func appsWithoutALastUsedDateAreNotUnused() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try Self.app(fx, "Applications/Mystery.app", id: "com.example.Mystery")
        let apps = Self.inventory(fx)
        #expect(apps.first?.lastUsed == nil)
        #expect(AppInventory.unused(apps, now: Self.now, days: 90).isEmpty)
    }

    @Test func unusedMeansNotOpenedInTheThreshold() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try Self.app(fx, "Applications/Old Small.app", id: "com.example.OldSmall", bytes: 10_000)
        try Self.app(fx, "Applications/Old Big.app", id: "com.example.OldBig", bytes: 900_000)
        try Self.app(fx, "Applications/Recent.app", id: "com.example.Recent")
        let apps = Self.inventory(fx, lastUsed: ["Old Small.app": 100, "Old Big.app": 200, "Recent.app": 30])
        #expect(AppInventory.unused(apps, now: Self.now, days: 90).map(\.name) == ["Old Big", "Old Small"])
        #expect(AppInventory.unused(apps, now: Self.now, days: 150).map(\.name) == ["Old Big"])
    }

    @Test func appsInstalledForAllUsersNeedAnAdministrator() async throws {
        let fx = try Fixture()
        let folder = fx.path("Applications")
        defer {
            chmod(folder, 0o755)
            fx.remove()
        }
        try Self.app(fx, "Applications/Shared.app", id: "com.example.Shared")
        #expect(Self.inventory(fx).first?.needsAdmin == false)
        #expect(chmod(folder, 0o555) == 0)
        #expect(Self.inventory(fx).first?.needsAdmin == true)
    }
}
