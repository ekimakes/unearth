import Foundation
import Testing
@testable import UnearthCore

struct DownloadsDetectorTests {
    @Test func classifiesInstallersAndArchives() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        for name in ["App.dmg", "Tool.pkg", "Xcode.xip", "photos.zip", "backup.tar.gz"] {
            try home.file("/Users/u/Downloads/\(name)", bytes: 2_000_000)
        }
        let tree = try await home.scan()
        let items = await DownloadsDetector().detect(in: .test(tree: tree, kb: try .test([])))
        let installers = Set(items.filter { $0.group == "Installers in Downloads" }.map(\.title))
        let archives = Set(items.filter { $0.group == "Archives in Downloads" }.map(\.title))
        #expect(installers == ["App.dmg", "Tool.pkg", "Xcode.xip"])
        #expect(archives == ["photos.zip", "backup.tar.gz"])
        #expect(items.allSatisfy { $0.safety == .review && $0.action == .trash && $0.section == .junk })
        #expect(items.first { $0.title == "App.dmg" }?.paths == ["/Users/u/Downloads/App.dmg"])
    }

    @Test func marksAlreadyUnzipped() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/Downloads/photos.zip", bytes: 2_000_000)
        try home.file("/Users/u/Downloads/photos/a.jpg", bytes: 2_000_000)
        try home.file("/Users/u/Downloads/other.zip", bytes: 2_000_000)
        let tree = try await home.scan()
        let items = await DownloadsDetector().detect(in: .test(tree: tree, kb: try .test([])))
        #expect(items.first { $0.title == "photos.zip" }?.subtitle == "Already unzipped")
        #expect(items.first { $0.title == "other.zip" }?.subtitle == nil)
    }

    @Test func ignoresOtherFiles() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/Downloads/report.pdf", bytes: 2_000_000)
        try home.file("/Users/u/Downloads/tiny.zip", bytes: 1_000)
        let tree = try await home.scan()
        #expect(await DownloadsDetector().detect(in: .test(tree: tree, kb: try .test([]))).isEmpty)
    }
}

struct DeviceBackupsDetectorTests {
    static let backups = "/Users/u/Library/Application Support/MobileSync/Backup"

    @Test func readsDeviceNameAndDate() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file(Self.backups + "/00008110-AAAA/Manifest.db", bytes: 3_000_000)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["Device Name": "Ana's iPhone", "Last Backup Date": Date(timeIntervalSince1970: 1_700_000_000)],
            format: .xml, options: 0)
        try info.write(to: URL(fileURLWithPath: home.fx.path("data" + Self.backups + "/00008110-AAAA/Info.plist")))
        let tree = try await home.scan()
        let items = await DeviceBackupsDetector().detect(in: .test(tree: tree, kb: try .test([])))
        let backup = try #require(items.first)
        #expect(items.count == 1)
        #expect(backup.title == "Ana's iPhone")
        #expect(backup.subtitle?.hasPrefix("Backed up ") == true)
        #expect(backup.safety == .review)
        #expect(backup.paths == [Self.backups + "/00008110-AAAA"])
        #expect(backup.bytes >= 3_000_000)
    }

    @Test func blocksWhenInaccessible() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        let manifest = try home.file(Self.backups + "/00008110-AAAA/Manifest.db", bytes: 10)
        let backupFolder = ((manifest as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        chmod(backupFolder, 0o000)
        defer { chmod(backupFolder, 0o755) }
        let tree = try await home.scan()
        let items = await DeviceBackupsDetector().detect(in: .test(tree: tree, kb: try .test([])))
        #expect(items.count == 1)
        #expect(items.first?.blockedReason == .needsFullDiskAccess)
        #expect(items.first?.title == "iPhone & iPad backups")
    }
}

struct TempFilesDetectorTests {
    @Test func onlyOldEntries() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        let now = Date()
        let temp = "/private/var/folders/xx/yy/T"
        try home.file(temp + "/old-folder/data", bytes: 2_000_000, modified: now.addingTimeInterval(-4 * 86_400))
        try home.file(temp + "/fresh.tmp", bytes: 2_000_000, modified: now.addingTimeInterval(-3_600))
        let tree = try await home.scan()
        let items = await TempFilesDetector(tempDirectory: temp).detect(in: .test(tree: tree, kb: try .test([]), now: now))
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.title == "Old temporary files")
        #expect(item.paths == [temp + "/old-folder"])
        #expect(item.safety == .safe)
        #expect(item.action == .trash)
    }
}

struct TrashReportDetectorTests {
    @Test func reportsTrashSize() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/.Trash/old movie.mov", bytes: 3_000_000)
        let tree = try await home.scan()
        let item = try #require(await TrashReportDetector().detect(in: .test(tree: tree, kb: try .test([]))).first)
        #expect(item.title == "Trash")
        #expect(item.bytes >= 3_000_000)
        #expect(item.action == .report(guidance: "Empty the Trash in Finder to get this space back."))
    }
}

struct SnapshotDetectorTests {
    @Test func parsesSnapshotCount() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/x", bytes: 10)
        let tree = try await home.scan()
        let runner = FakeCommandRunner(["/usr/bin/tmutil listlocalsnapshots /": .success(try Fixtures.data("tmutil-list.txt"))])
        let item = try #require(await SnapshotDetector().detect(in: .test(tree: tree, kb: try .test([]), runner: runner)).first)
        #expect(item.title == "Time Machine local snapshots (2)")
        #expect(item.safety == .review)
        #expect(item.isPermanent)
        #expect(item.action == .tool(ToolCommand(toolName: "Time Machine", executable: "/usr/bin/tmutil",
                                                 arguments: ["deletelocalsnapshots", "/"], needsAdmin: true)))
    }

    @Test func noItemWhenNone() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/x", bytes: 10)
        let tree = try await home.scan()
        let runner = FakeCommandRunner(["/usr/bin/tmutil listlocalsnapshots /": .success("Snapshots for disk /:\n")])
        #expect(await SnapshotDetector().detect(in: .test(tree: tree, kb: try .test([]), runner: runner)).isEmpty)
    }
}
