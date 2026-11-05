import Foundation
import Testing
@testable import UnearthCore

@Suite struct SavedScanTests {
    private func scannedTree(_ fx: Fixture) async throws -> ScanTree {
        try fx.file("data/Users/me/Movies/big.mov", bytes: 60_000_000)
        try fx.file("data/Users/me/Documents/note.txt", bytes: 2_000)
        try fx.file("data/Users/me/Code/app/package.json", bytes: 100)
        try fx.file("data/Users/me/Pictures/é and 日本/photo.jpg", bytes: 9_000)
        return try await DiskScanner().scan(ScanOptions(rootPath: fx.path("data"), displayRoot: "/"))
    }

    @Test func aTreeComesBackTheSame() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let tree = try await scannedTree(fx)
        let back = try #require(ScanTree.unarchived(tree.archived()))
        #expect(back.nodeCount == tree.nodeCount)
        for raw in 0..<Int32(tree.nodeCount) {
            #expect(back.node(NodeID(raw: raw)) == tree.node(NodeID(raw: raw)))
            #expect(back.path(of: NodeID(raw: raw)) == tree.path(of: NodeID(raw: raw)))
        }
        #expect(back.rootPath == tree.rootPath)
        #expect(back.displayRoot == tree.displayRoot)
        #expect(back.bigFiles == tree.bigFiles)
        #expect(back.stats == tree.stats)
        #expect(back.isInsideCodeProject("/Users/me/Code/app/package.json") == true)
    }

    @Test func damagedDataReadsAsNothing() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let bytes = try await scannedTree(fx).archived()
        #expect(ScanTree.unarchived(Data()) == nil)
        #expect(ScanTree.unarchived(bytes.prefix(bytes.count / 2)) == nil)
        var otherVersion = bytes
        otherVersion[4] &+= 1
        #expect(ScanTree.unarchived(otherVersion) == nil)
    }

    @Test func aParentOutsideTheTreeReadsAsNothing() {
        let stats = ScanStats(files: 0, directories: 2, inaccessibleDirectories: 0, mountPointsSkipped: 0, cloudOnlyFiles: 0, elapsed: .zero)
        let node = ScanNode(name: "x", parent: NodeID(raw: 9), children: [], ownBytes: 0, ownMediaBytes: 0, ownFileCount: 0, markers: [],
                            isInaccessible: false, totalBytes: 0, totalMediaBytes: 0, totalFileCount: 0,
                            newestOwnModification: nil, newestModification: nil)
        let root = ScanNode(name: "", parent: nil, children: [NodeID(raw: 1)], ownBytes: 0, ownMediaBytes: 0, ownFileCount: 0, markers: [],
                            isInaccessible: false, totalBytes: 0, totalMediaBytes: 0, totalFileCount: 0,
                            newestOwnModification: nil, newestModification: nil)
        let tree = ScanTree(nodes: [root, node], rootPath: "/", displayRoot: "/", bigFiles: [], stats: stats)
        #expect(ScanTree.unarchived(tree.archived()) == nil)
    }

    @Test func aSavedScanIsReadBackWithItsAge() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let saved = SavedScan(fileURL: URL(fileURLWithPath: fx.path("support/last-scan.bin")))
        #expect(saved.load() == nil)
        let tree = try await scannedTree(fx)
        try saved.save(tree, fullDiskAccess: true)
        let loaded = try #require(saved.load())
        #expect(loaded.tree.nodeCount == tree.nodeCount)
        #expect(loaded.hadFullDiskAccess)
        #expect(loaded.age < 60)
        #expect(loaded.isFresh)
    }

    @Test func aCleanupMakesTheSavedScanOutdated() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let saved = SavedScan(fileURL: URL(fileURLWithPath: fx.path("last-scan.bin")))
        try saved.save(try await scannedTree(fx), fullDiskAccess: false)
        saved.markOutdated()
        let loaded = try #require(saved.load())
        #expect(!loaded.hadFullDiskAccess)
        #expect(!loaded.isFresh)
    }

    @Test func forgettingRemovesTheSavedScan() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let saved = SavedScan(fileURL: URL(fileURLWithPath: fx.path("last-scan.bin")))
        try saved.save(try await scannedTree(fx), fullDiskAccess: true)
        saved.forget()
        #expect(saved.load() == nil)
    }
}
