import Foundation
import Testing
@testable import UnearthCore

/// What left the disk leaves the screens at once, ahead of the next look and the next scan.
struct RemovalTests {
    private static func file(_ id: Int64, _ path: String, bytes: Int64 = 1_000) -> IndexedFile {
        let name = (path as NSString).lastPathComponent
        return IndexedFile(id: id, path: path, name: name, parent: (path as NSString).deletingLastPathComponent, kind: .image,
                           fileExtension: "jpg", bytes: bytes, created: nil, modified: .distantPast,
                           added: Date(timeIntervalSince1970: Double(id)), source: nil, isCloudOnly: false)
    }

    private static func group(_ paths: [String], sharing: Set<String> = []) -> DuplicateGroup {
        DuplicateGroup(id: "hash", copies: paths.enumerated().map { file(Int64($0 + 1), $1) }, downloads: "/u/Downloads",
                       sharesStorage: { sharing.contains($0) && sharing.contains($1) })
    }

    private static func scanned(_ fx: Fixture) async throws -> ScanTree {
        try await DiskScanner().scan(ScanOptions(rootPath: fx.path("data"), displayRoot: "/"))
    }

    // MARK: - Duplicates

    @Test func aGroupLosesTheCopiesThatLeft() throws {
        let group = Self.group(["/u/a.jpg", "/u/b.jpg", "/u/c.jpg"])
        let left = try #require(group.without { $0.path == "/u/c.jpg" })
        #expect(left.files.map(\.path) == ["/u/a.jpg", "/u/b.jpg"])
        #expect(left.id == group.id && left.keep == group.keep)
        #expect(left.defaultSelection() == [left.files[1].id])
        #expect(left.extraBytes == 1_000)
    }

    @Test func oneCopyLeftIsNoLongerADuplicate() {
        let group = Self.group(["/u/a.jpg", "/u/b.jpg"])
        #expect(group.without { $0.path == "/u/b.jpg" } == nil)
        #expect(group.without { _ in true } == nil)
    }

    @Test func aKeptCopyThatLeftHandsOverToTheNext() throws {
        var group = Self.group(["/u/a.jpg", "/u/b.jpg", "/u/c.jpg"])
        group.keep = group.files[1].id
        let kept = group.keep
        let left = try #require(group.without { $0.id == kept })
        #expect(left.files.map(\.path) == ["/u/a.jpg", "/u/c.jpg"])
        #expect(left.keep == left.files[0].id)
    }

    @Test func clonesStayClonesWhenAnotherCopyLeaves() throws {
        let group = Self.group(["/u/a.jpg", "/u/b.jpg", "/u/c.jpg"], sharing: ["/u/a.jpg", "/u/b.jpg"])
        let left = try #require(group.without { $0.path == "/u/c.jpg" })
        #expect(left.clones == [left.files[1].id])
        #expect(left.extraBytes == 0)
    }

    // MARK: - Look-alikes

    @Test func aLookAlikeGroupLosesThePhotosThatLeft() throws {
        let files = [Self.file(1, "/u/a.jpg"), Self.file(2, "/u/b.jpg"), Self.file(3, "/u/c.jpg")]
        let group = LookAlikeGroup(id: "1,2,3", files: files, best: 2)
        let left = try #require(group.without { $0.id == 3 })
        #expect(left.files.map(\.id) == [1, 2])
        #expect(left.best == 2 && left.id == group.id)
        #expect(group.without { $0.id != 1 } == nil)
    }

    @Test func aBestShotThatLeftHandsOverToTheNext() throws {
        let files = [Self.file(1, "/u/a.jpg"), Self.file(2, "/u/b.jpg"), Self.file(3, "/u/c.jpg")]
        let group = LookAlikeGroup(id: "1,2,3", files: files, best: 2)
        let left = try #require(group.without { $0.id == 2 })
        #expect(left.best == 1)
    }

    // MARK: - What left

    @Test func aFolderCoversWhatWasInIt() {
        var removed = RemovedPaths()
        removed.insert(contentsOf: ["/u/Old", "/u/Docs/a.pdf"])
        #expect(removed.covers("/u/Old"))
        #expect(removed.covers("/u/Old/deep/b.jpg"))
        #expect(removed.covers("/u/Docs/a.pdf"))
        #expect(!removed.covers("/u/Older/b.jpg"))
        #expect(!removed.covers("/u/Docs/a.pdf.bak"))
        #expect(!removed.covers("/u/Docs"))
    }

    @Test func pathsCompareTheWayTheDiskDoes() {
        var removed = RemovedPaths()
        removed.insert(contentsOf: ["/u/Cafe\u{301}"])
        #expect(removed.covers("/U/CAF\u{C9}/menu.pdf"))
    }

    @Test func whatCameBackIsCoveredNoMore() {
        var removed = RemovedPaths()
        removed.insert(contentsOf: ["/u/a.jpg", "/u/b.jpg"])
        removed.forget(["/u/a.jpg"])
        #expect(!removed.covers("/u/a.jpg"))
        #expect(removed.covers("/u/b.jpg"))
        #expect(removed.paths == ["/u/b.jpg"])
    }

    // MARK: - The index

    @Test func aFolderLeavesTheIndexWithWhatWasInIt() async throws {
        let index = try FileIndex.inMemory()
        try await index.upsert([
            FileIndexTests.record("/u/Old/a.jpg"), FileIndexTests.record("/u/Old/deep/b.jpg"),
            FileIndexTests.record("/u/Older/c.jpg"), FileIndexTests.record("/u/d.jpg"),
        ], generation: await index.beginPass())
        try await index.remove(paths: ["/u/Old", "/u/d.jpg"])
        #expect(await FileIndexTests.all(index).map(\.path) == ["/u/Older/c.jpg"])
    }

    // MARK: - The scan

    @Test func aFolderLeavesEveryFolderAboveIt() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("data/Users/me/Old/a.bin", bytes: 3_000_000)
        try fx.file("data/Users/me/Old/deep/b.bin", bytes: 2_000_000)
        try fx.file("data/Users/me/Keep/c.bin", bytes: 1_000_000)
        let tree = try await Self.scanned(fx)
        let me = try #require(tree.node(atPath: "/Users/me"))
        let old = try #require(tree.node(atPath: "/Users/me/Old"))

        let after = tree.removing([(path: "/Users/me/Old", bytes: 0)])
        #expect(after.id != tree.id)
        #expect(after.node(atPath: "/Users/me/Old") == nil)
        #expect(after.node(atPath: "/Users/me/Old/deep") == nil)
        let smaller = try #require(after.node(atPath: "/Users/me"))
        #expect(smaller.totalBytes == me.totalBytes - old.totalBytes)
        #expect(smaller.totalFileCount == me.totalFileCount - old.totalFileCount)
        #expect(smaller.children.count == me.children.count - 1)
        #expect(after.node(after.rootID).totalBytes == tree.node(tree.rootID).totalBytes - old.totalBytes)
        #expect(after.node(atPath: "/Users/me/Keep") == tree.node(atPath: "/Users/me/Keep"))
    }

    @Test func aFileLeavesItsFolderSmaller() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("data/Users/me/Keep/c.bin", bytes: 1_000_000)
        try fx.file("data/Users/me/Keep/d.bin", bytes: 500_000)
        let tree = try await Self.scanned(fx)
        let keep = try #require(tree.node(atPath: "/Users/me/Keep"))

        let after = tree.removing([(path: "/Users/me/Keep/d.bin", bytes: 500_000)])
        let smaller = try #require(after.node(atPath: "/Users/me/Keep"))
        #expect(smaller.ownBytes == keep.ownBytes - 500_000)
        #expect(smaller.ownFileCount == keep.ownFileCount - 1)
        #expect(smaller.totalBytes == keep.totalBytes - 500_000)
        #expect(after.node(after.rootID).totalBytes == tree.node(tree.rootID).totalBytes - 500_000)
    }

    @Test func bigFilesThatLeftAreOffTheList() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("data/Users/me/Movies/one.mov", bytes: 60_000_000)
        try fx.file("data/Users/me/Old/two.mov", bytes: 70_000_000)
        try fx.file("data/Users/me/Keep/three.mov", bytes: 80_000_000)
        let tree = try await Self.scanned(fx)
        #expect(tree.bigFiles.count == 3)
        let after = tree.removing([(path: "/Users/me/Movies/one.mov", bytes: 60_000_000), (path: "/Users/me/Old", bytes: 0)])
        #expect(after.bigFiles.map(\.path) == ["/Users/me/Keep/three.mov"])
    }

    @Test func foldersStaySortedBySize() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("data/Users/me/Big/a.bin", bytes: 1_000_000)
        try fx.file("data/Users/me/Big/b.bin", bytes: 3_000_000)
        try fx.file("data/Users/me/Middle/c.bin", bytes: 2_000_000)
        let tree = try await Self.scanned(fx)
        let after = tree.removing([(path: "/Users/me/Big/b.bin", bytes: 3_000_000)])
        let me = try #require(after.node(atPath: "/Users/me"))
        #expect(me.children.map { after.node($0).name } == ["Middle", "Big"])
    }

    @Test func sizesNeverGoBelowZero() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("data/Users/me/Keep/c.bin", bytes: 1_000)
        let tree = try await Self.scanned(fx)
        let after = tree.removing([(path: "/Users/me/Keep/gone.bin", bytes: 999_999_999)])
        #expect(try #require(after.node(atPath: "/Users/me/Keep")).totalBytes == 0)
        #expect(after.node(after.rootID).totalBytes == 0)
    }

    @Test func whatTheScanNeverSawChangesNothing() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("data/Users/me/Keep/c.bin", bytes: 1_000)
        let tree = try await Self.scanned(fx)
        let after = tree.removing([(path: "/Volumes/Other/x.bin", bytes: 1_000)])
        #expect(after.node(after.rootID) == tree.node(tree.rootID))
    }

    // MARK: - The confirmation

    @Test func oneThingGoesByItsName() {
        #expect(CleanupMessage.removed(["IMG_2041.jpg"], kind: .duplicates) == "Removed “IMG_2041.jpg”")
        #expect(CleanupMessage.removed(["Slack"]) == "Removed “Slack”")
    }

    @Test func severalGoByHowMany() {
        #expect(CleanupMessage.removed(["a", "b"], kind: .duplicates) == "Removed 2 duplicates")
        #expect(CleanupMessage.removed(["a", "b", "c"], kind: .oldScreenshots) == "Removed 3 old screenshots")
        #expect(CleanupMessage.removed(["a", "b"], kind: .lookAlikes) == "Removed 2 photos")
        #expect(CleanupMessage.removed(["a", "b"]) == "Removed 2 items")
    }

    @Test func theDetailSaysWhereItWent() {
        let size = ByteFormatting.string(1_400_000)
        #expect(CleanupMessage.detail(bytes: 1_400_000) == "\(size) moved to the Trash. Empty the Trash to get the space back.")
    }

    @Test func deletingSaysWhatWentForGood() {
        #expect(CleanupMessage.deleted(["IMG_2041.jpg"]) == "Deleted “IMG_2041.jpg” permanently")
        #expect(CleanupMessage.deleted(["a", "b", "c"]) == "Deleted 3 items permanently")
    }

    @Test func deletingSaysTheSpaceIsBack() {
        let size = ByteFormatting.string(1_400_000)
        #expect(CleanupMessage.deletedDetail(bytes: 1_400_000) == "\(size) of space is back.")
        #expect(CleanupMessage.deletedDetail(bytes: 0) == "This freed no space on this Mac.")
    }

    @Test func nothingFreedIsSaidPlainly() {
        #expect(CleanupMessage.detail(bytes: 0) == "Moved to the Trash. This frees no space on this Mac.")
    }
}
