import Foundation
import Testing
@testable import UnearthCore

struct StorageBreakdownTests {
    static let home = "/Users/demo"
    static let mb = 1_000_000

    /// A small fake Data volume with one file in every interesting place.
    static func scanFixture() async throws -> (Fixture, ScanTree) {
        let fx = try Fixture()
        let files = [
            "Applications/App.app/Contents/bin",
            "Users/demo/Documents/report.pdf",
            "Users/demo/Pictures/Photos Library.photoslibrary/database",
            "Users/demo/Library/Application Support/MobileSync/Backup/abc/Manifest.db",
            "Users/demo/Library/Developer/Xcode/DerivedData/App-x/Build",
            "Users/demo/Library/Caches/com.example.app/cache.db",
            "Users/demo/Library/Caches/Homebrew/bottle.tar.gz",
            "Users/demo/.ollama/models/blob",
            "Users/demo/Library/Logs/app.log",
            "Users/demo/Library/Mail/V10/mailbox",
            "Users/demo/.Trash/old.zip",
            "Users/demo/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
            "Users/demo/Library/Preferences/com.example.plist",
            "Library/Developer/CoreSimulator/Images/runtime.dmg",
            "private/var/folders/xx/T/temp.bin",
            "usr/local/bin/tool",
            "Users/other/secret",
        ]
        for file in files { try fx.file("data/" + file, bytes: mb) }
        try fx.file("data/Users/demo/Desktop/clip.mov", bytes: 3 * mb)
        let tree = try await DiskScanner().scan(ScanOptions(rootPath: fx.path("data"), displayRoot: "/"))
        return (fx, tree)
    }

    static func inventory(dataInUse: Int64, overhead: Int64 = Int64(mb), extraVolumes: [APFSVolume] = []) -> VolumeInventory {
        var volumes = [
            APFSVolume(deviceIdentifier: "disk3s1", name: "Macintosh HD", roles: ["System"], capacityInUse: 5 * Int64(mb)),
            APFSVolume(deviceIdentifier: "disk3s5", name: "Data", roles: ["Data"], capacityInUse: dataInUse),
            APFSVolume(deviceIdentifier: "disk3s6", name: "VM", roles: ["VM"], capacityInUse: 2 * Int64(mb)),
            APFSVolume(deviceIdentifier: "disk3s2", name: "Preboot", roles: ["Preboot"], capacityInUse: Int64(mb)),
            APFSVolume(deviceIdentifier: "disk3s3", name: "Recovery", roles: ["Recovery"], capacityInUse: Int64(mb)),
            APFSVolume(deviceIdentifier: "disk3s4", name: "Update", roles: ["Update"], capacityInUse: 0),
        ]
        volumes += extraVolumes
        let used = volumes.reduce(0) { $0 + $1.capacityInUse } + overhead
        let free: Int64 = 1_000_000_000
        let container = APFSContainer(reference: "disk3", capacity: used + free, free: free, volumes: volumes)
        return VolumeInventory(container: container, available: free, availableForImportantUsage: free + 7)
    }

    static func size(_ tree: ScanTree, _ path: String) -> Int64 {
        tree.nodeID(forPath: path).map { tree.node($0).totalBytes } ?? -1
    }

    @Test func segmentsSumToUsed() async throws {
        let (fx, tree) = try await Self.scanFixture()
        defer { fx.remove() }
        let volumes = Self.inventory(dataInUse: tree.node(tree.rootID).totalBytes + 10 * Int64(Self.mb))
        let breakdown = StorageBreakdown.compute(tree: tree, volumes: volumes, homePath: Self.home)
        #expect(breakdown.segments.values.reduce(0, +) == breakdown.used)
        #expect(breakdown.used == volumes.used)
        #expect(breakdown.free == volumes.container.free)
        #expect(breakdown.purgeable == 7)
    }

    @Test func bucketsSumToSystemData() async throws {
        let (fx, tree) = try await Self.scanFixture()
        defer { fx.remove() }
        let breakdown = StorageBreakdown.compute(
            tree: tree, volumes: Self.inventory(dataInUse: tree.node(tree.rootID).totalBytes), homePath: Self.home)
        #expect(breakdown.systemData.values.reduce(0, +) == breakdown.segments[.systemData])
    }

    @Test func assignsRepresentativePaths() async throws {
        let (fx, tree) = try await Self.scanFixture()
        defer { fx.remove() }
        let breakdown = StorageBreakdown.compute(
            tree: tree, volumes: Self.inventory(dataInUse: tree.node(tree.rootID).totalBytes, overhead: 0), homePath: Self.home)
        let size = { Self.size(tree, $0) }
        #expect(breakdown.segments[.apps] == size("/Applications"))
        #expect(breakdown.segments[.iosBackups] == size("/Users/demo/Library/Application Support/MobileSync"))
        #expect(breakdown.segments[.developer] == size("/Users/demo/Library/Developer"))
        #expect(breakdown.segments[.macOS] == 5 * Int64(Self.mb))
        #expect(breakdown.segments[.other] == size("/Users/demo/Library/Mail") + size("/Users/demo/.Trash") + size("/Users/other"))
        #expect(breakdown.systemData[.appCaches] == size("/Users/demo/Library/Caches/com.example.app"))
        #expect(breakdown.systemData[.devCaches] == size("/Users/demo/Library/Caches/Homebrew"))
        #expect(breakdown.systemData[.aiModels] == size("/Users/demo/.ollama"))
        #expect(breakdown.systemData[.logs] == size("/Users/demo/Library/Logs"))
        #expect(breakdown.systemData[.virtualMachines] == size("/Users/demo/Library/Containers/com.docker.docker"))
        #expect(breakdown.systemData[.developerTools] == size("/Library/Developer") + size("/usr/local"))
        #expect(breakdown.systemData[.tempFiles] == size("/private/var/folders"))
        #expect(breakdown.systemData[.appData] == size("/Users/demo/Library/Preferences"))
        #expect(breakdown.systemData[.swap] == 2 * Int64(Self.mb))
        #expect(breakdown.systemData[.systemSupport] == 2 * Int64(Self.mb))
        #expect(breakdown.systemData[.notIdentified] == 0)
    }

    @Test func splitsMediaFromDocuments() async throws {
        let (fx, tree) = try await Self.scanFixture()
        defer { fx.remove() }
        let breakdown = StorageBreakdown.compute(
            tree: tree, volumes: Self.inventory(dataInUse: tree.node(tree.rootID).totalBytes), homePath: Self.home)
        let photosLibrary = Self.size(tree, "/Users/demo/Pictures/Photos Library.photoslibrary")
        let clip = Self.size(tree, "/Users/demo/Desktop")
        #expect(breakdown.segments[.photosVideos] == photosLibrary + clip)
        #expect(breakdown.segments[.documents] == Self.size(tree, "/Users/demo/Documents"))
    }

    @Test func notIdentifiedIsRemainder() async throws {
        let (fx, tree) = try await Self.scanFixture()
        defer { fx.remove() }
        let volumes = Self.inventory(dataInUse: tree.node(tree.rootID).totalBytes + 10 * Int64(Self.mb))
        let breakdown = StorageBreakdown.compute(tree: tree, volumes: volumes, homePath: Self.home)
        #expect(breakdown.systemData[.notIdentified] == 11 * Int64(Self.mb))
        #expect(breakdown.overcount == 0)
    }

    @Test func clampsOvercount() async throws {
        let (fx, tree) = try await Self.scanFixture()
        defer { fx.remove() }
        let volumes = Self.inventory(dataInUse: tree.node(tree.rootID).totalBytes - 5 * Int64(Self.mb), overhead: 0)
        let breakdown = StorageBreakdown.compute(tree: tree, volumes: volumes, homePath: Self.home)
        #expect(breakdown.systemData[.notIdentified] == 0)
        #expect(breakdown.overcount == 5 * Int64(Self.mb))
        #expect(breakdown.segments.values.reduce(0, +) == breakdown.used)
        #expect(breakdown.systemData.values.reduce(0, +) == breakdown.segments[.systemData])
    }

    @Test func unknownVolumesCountAsOther() async throws {
        let (fx, tree) = try await Self.scanFixture()
        defer { fx.remove() }
        let extra = APFSVolume(deviceIdentifier: "disk3s7", name: "Projects", roles: [], capacityInUse: 4 * Int64(Self.mb))
        let breakdown = StorageBreakdown.compute(
            tree: tree, volumes: Self.inventory(dataInUse: tree.node(tree.rootID).totalBytes, extraVolumes: [extra]),
            homePath: Self.home)
        #expect(breakdown.segments[.other] ?? 0 >= 4 * Int64(Self.mb))
        #expect(breakdown.segments.values.reduce(0, +) == breakdown.used)
    }

    @Test func contributorsCountOnlyTheirBucketsBytes() async throws {
        let (fx, tree) = try await Self.scanFixture()
        defer { fx.remove() }
        let breakdown = StorageBreakdown.compute(
            tree: tree, volumes: Self.inventory(dataInUse: tree.node(tree.rootID).totalBytes), homePath: Self.home)
        let caches = try #require(breakdown.bucketContributors[.appCaches]?.first { tree.path(of: $0.node) == "/Users/demo/Library/Caches" })
        #expect(caches.bytes == Self.size(tree, "/Users/demo/Library/Caches/com.example.app"))
        let roots = breakdown.bucketContributors.values.flatMap { $0 }.map(\.node)
        #expect(!roots.contains(tree.rootID))
    }

    @Test func categoriesKnowTheirBiggestFolders() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("data/Users/demo/Pictures/trip.jpg", bytes: 3 * Self.mb)
        try fx.file("data/Users/demo/Movies/film.mov", bytes: 5 * Self.mb)
        try fx.file("data/Users/demo/Documents/report.pdf", bytes: 2 * Self.mb)
        try fx.file("data/Users/demo/Library/Developer/Xcode/DerivedData/App/Build", bytes: Self.mb)
        try fx.file("data/Applications/App.app/Contents/bin", bytes: Self.mb)
        let tree = try await DiskScanner().scan(ScanOptions(rootPath: fx.path("data"), displayRoot: "/"))
        let breakdown = StorageBreakdown.compute(
            tree: tree, volumes: Self.inventory(dataInUse: tree.node(tree.rootID).totalBytes), homePath: Self.home)
        func folders(_ category: StorageCategory) -> [String] {
            (breakdown.categoryContributors[category] ?? []).map { tree.path(of: $0.node) }
        }
        #expect(folders(.photosVideos) == ["/Users/demo/Movies", "/Users/demo/Pictures"])
        #expect(folders(.documents).first == "/Users/demo/Documents")
        #expect(folders(.developer) == ["/Users/demo/Library/Developer"])
        #expect(folders(.apps) == ["/Applications"])
        #expect(folders(.macOS).isEmpty)
        let movies = try #require(breakdown.categoryContributors[.photosVideos]?.first)
        #expect(movies.bytes >= Int64(5 * Self.mb))
    }
}

