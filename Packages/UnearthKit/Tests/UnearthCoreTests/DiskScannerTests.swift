import Darwin
import Foundation
import Testing
@testable import UnearthCore

struct DiskScannerTests {
    let scanner = DiskScanner()

    @Test func totalsMatchOracle() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        for i in 0..<2_000 {
            try fx.file("a\(i % 4)/b\(i % 7)/c\(i % 3)/f\(i)", bytes: Int.random(in: 0...50_000))
        }
        let tree = try await scanner.scan(ScanOptions(rootPath: fx.root))

        let oracle = try Self.allocatedTotal(of: fx.root)
        #expect(tree.node(tree.rootID).totalBytes == oracle)
        #expect(tree.stats.files == 2_000)

        var stack = [tree.rootID]
        while let id = stack.popLast() {
            let node = tree.node(id)
            let childTotal = node.children.reduce(Int64(0)) { $0 + tree.node($1).totalBytes }
            #expect(node.totalBytes == node.ownBytes + childTotal)
            stack.append(contentsOf: node.children)
        }
    }

    /// Oracle: FileManager's allocated sizes of every regular file under `root`.
    static func allocatedTotal(of root: String) throws -> Int64 {
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])!
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values.isRegularFile == true { total += Int64(values.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    @Test func countsHardLinksOnce() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let original = try fx.file("one/data", bytes: 3_000_000)
        try fx.dir("two")
        try fx.hardLink(original, fx.path("two/data-link"))
        let tree = try await scanner.scan(ScanOptions(rootPath: fx.root))
        let allocated = try URL(fileURLWithPath: original).resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize!
        #expect(tree.node(tree.rootID).totalBytes == Int64(allocated))
    }

    @Test func countsClonesOnce() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let source = try fx.file("movie.mov", bytes: 4_000_000)
        try fx.dir("copies")
        try fx.clone(source, fx.path("copies/movie copy.mov"))
        let tree = try await scanner.scan(ScanOptions(rootPath: fx.root))
        #expect(tree.node(tree.rootID).totalBytes < 4_100_000)
        #expect(tree.node(tree.rootID).totalBytes >= 4_000_000)
    }

    @Test func skipsDatalessAndMountPoints() async throws {
        let reader = FakeDirectoryReader(listings: [
            "/r": [.fakeFile("cloud.pdf", bytes: 0, dataless: true), .fakeFile("local.txt", bytes: 4096),
                   .fakeDirectory("Volume", mountPoint: true), .fakeDirectory("sub")],
            "/r/sub": [.fakeFile("x", bytes: 8192)],
        ])
        let tree = try await DiskScanner(reader: reader).scan(ScanOptions(rootPath: "/r"))
        #expect(tree.stats.cloudOnlyFiles == 1)
        #expect(tree.stats.mountPointsSkipped == 1)
        let names = tree.node(tree.rootID).children.map { tree.node($0).name }
        #expect(names == ["sub"])
        #expect(tree.node(tree.rootID).totalBytes == 4096 + 8192)
    }

    @Test func survivesVanishingAndUnreadableDirectories() async throws {
        let reader = FakeDirectoryReader(
            listings: [
                "/r": [.fakeDirectory("gone"), .fakeDirectory("locked"), .fakeDirectory("ok")],
                "/r/ok": [.fakeFile("f", bytes: 4096)],
            ],
            failures: ["/r/gone": .notFound, "/r/locked": .permissionDenied])
        let tree = try await DiskScanner(reader: reader).scan(ScanOptions(rootPath: "/r"))
        let children = tree.node(tree.rootID).children.map { tree.node($0) }
        #expect(!children.contains { $0.name == "gone" })
        let locked = try #require(children.first { $0.name == "locked" })
        #expect(locked.isInaccessible)
        #expect(tree.stats.inaccessibleDirectories == 1)
        #expect(tree.node(tree.rootID).totalBytes == 4096)
    }

    @Test func scansTreeDeeperThanPathMax() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let components = (0..<25).map { "level-\($0)-" + String(repeating: "y", count: 52) }
        let deepest = try fx.deepDirectory(components, fileName: "bottom.bin", bytes: 100_000)
        #expect(deepest.utf8.count > 1_500)
        let tree = try await scanner.scan(ScanOptions(rootPath: fx.root))
        #expect(tree.node(tree.rootID).totalBytes >= 100_000)
        #expect(tree.stats.inaccessibleDirectories == 0)
    }

    @Test func recordsBigFilesMarkersAndMedia() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("proj/package.json", bytes: 100)
        try fx.file("proj/huge.bin", bytes: 60_000_000)
        try fx.file("proj/photo.HEIC", bytes: 2_000_000)
        let tree = try await scanner.scan(ScanOptions(rootPath: fx.root))
        #expect(tree.bigFiles.count == 1)
        #expect(tree.bigFiles.first?.path == fx.path("proj/huge.bin"))
        let project = try #require(tree.nodeID(forPath: fx.path("proj")).map(tree.node))
        #expect(project.markers.contains(.packageJSON))
        #expect(project.ownMediaBytes >= 2_000_000)
        #expect(project.ownMediaBytes < 3_000_000)
    }

    @Test func gitAndUnityMarkProjects() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("p/.git/HEAD", bytes: 10)
        try fx.file("u/ProjectSettings/x", bytes: 10)
        let tree = try await scanner.scan(ScanOptions(rootPath: fx.root))
        #expect(tree.node(atPath: fx.path("p"))?.markers.contains(.gitRepository) == true)
        #expect(tree.node(atPath: fx.path("u"))?.markers.contains(.unityProject) == true)
    }

    @Test func findsTheEnclosingProject() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("data/p/package.json", bytes: 10)
        try fx.file("data/p/src/a/b.png", bytes: 10)
        try fx.file("data/photos/c.png", bytes: 10)
        let tree = try await scanner.scan(ScanOptions(rootPath: fx.path("data"), displayRoot: "/r"))
        #expect(tree.isInsideCodeProject("/r/p/src/a/b.png"))
        #expect(tree.isInsideCodeProject("/r/p/b.png"))
        #expect(!tree.isInsideCodeProject("/r/photos/c.png"))
        #expect(!tree.isInsideCodeProject("/elsewhere/p/b.png"))
    }

    /// A dotfiles repository or a stray package.json in the home folder doesn't make all of it a project.
    @Test func homeFolderMarkersDontCount() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("data/me/.git/HEAD", bytes: 10)
        try fx.file("data/me/package.json", bytes: 10)
        try fx.file("data/me/Pictures/c.png", bytes: 10)
        try fx.file("data/me/code/app/.git/HEAD", bytes: 10)
        try fx.file("data/me/code/app/icon.png", bytes: 10)
        let tree = try await scanner.scan(ScanOptions(rootPath: fx.path("data"), displayRoot: "/r"))
        #expect(!tree.isInsideCodeProject("/r/me/Pictures/c.png", home: "/r/me"))
        #expect(tree.isInsideCodeProject("/r/me/code/app/icon.png", home: "/r/me"))
        #expect(tree.isInsideCodeProject("/r/me/Pictures/c.png"))
    }

    @Test func mapsDisplayRoot() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("data/Users/x/notes.txt", bytes: 10)
        let tree = try await scanner.scan(ScanOptions(rootPath: fx.path("data"), displayRoot: "/"))
        let id = try #require(tree.nodeID(forPath: "/Users/x"))
        #expect(tree.path(of: id) == "/Users/x")
        #expect(tree.path(of: tree.rootID) == "/")
    }

    @Test func mapsDisplayPathsBackToRealPaths() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("data/Users/x/notes.txt", bytes: 10)
        let mapped = try await scanner.scan(ScanOptions(rootPath: fx.path("data"), displayRoot: "/"))
        #expect(mapped.realPath(forDisplayPath: "/Users/x") == fx.path("data/Users/x"))
        #expect(mapped.realPath(forDisplayPath: "/") == fx.path("data"))
        let plain = try await scanner.scan(ScanOptions(rootPath: fx.path("data")))
        #expect(plain.realPath(forDisplayPath: fx.path("data/Users")) == fx.path("data/Users"))
    }

    @Test func honorsCancellation() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("a/b", bytes: 10)
        let task = Task { try await scanner.scan(ScanOptions(rootPath: fx.root)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
