import Foundation
import Synchronization
import Testing
@testable import UnearthCore

/// Hashes with another hasher and remembers which files it read.
final class CountingHasher: FileHashing {
    private let base: any FileHashing
    private let calls = Mutex<(partial: [String], full: [String])>(([], []))

    init(_ base: any FileHashing = SHA256Hasher()) { self.base = base }

    var partialReads: [String] { calls.withLock { $0.partial } }
    var fullReads: [String] { calls.withLock { $0.full } }
    func reset() { calls.withLock { $0 = ([], []) } }

    func partialHash(of path: String) throws -> String {
        calls.withLock { $0.partial.append(path) }
        return try base.partialHash(of: path)
    }

    func fullHash(of path: String) throws -> String {
        calls.withLock { $0.full.append(path) }
        return try base.fullHash(of: path)
    }
}

/// Answers from tables, for files that don't exist (like two 50 GB disk images).
struct TableHasher: FileHashing {
    let partial: [String: String]
    let full: [String: String]

    func partialHash(of path: String) throws -> String { partial[path] ?? path }
    func fullHash(of path: String) throws -> String { full[path] ?? path }
}

struct DuplicatesTests {
    /// Bytes that differ from one seed to another everywhere.
    static func pattern(_ seed: Int, size: Int = 200_000) -> Data {
        var bytes = [UInt8](repeating: 0, count: size)
        for i in 0..<size { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ seed &* 7 &+ (i >> 9)) }
        return Data(bytes)
    }

    @discardableResult
    static func write(_ fx: Fixture, _ relative: String, _ data: Data) throws -> String {
        let path = fx.path(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    static func record(_ path: String, added: Double, bytes: Int64? = nil, modified: Double = 1_000,
                       cloud: Bool = false) -> IndexedFileRecord {
        let size = bytes ?? ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
        return FileIndexTests.record(path, kind: .image, bytes: size, added: added, modified: modified, cloud: cloud)
    }

    static func index(_ records: [IndexedFileRecord]) async throws -> FileIndex {
        let index = try FileIndex.inMemory()
        try await index.upsert(records, generation: await index.beginPass())
        return index
    }

    static func finder(
        _ index: FileIndex, downloads: String = "/nowhere/Downloads", hasher: any FileHashing = SHA256Hasher(),
        isInCodeProject: @escaping @Sendable (String) -> Bool = { _ in false }, paused: Bool = false
    ) -> DuplicateFinder {
        DuplicateFinder(index: index, downloads: downloads, hasher: hasher, isInCodeProject: isInCodeProject,
                        power: FakePower(paused: paused))
    }

    static func names(_ group: DuplicateGroup, _ ids: some Sequence<Int64>) -> Set<String> {
        Set(ids.compactMap { id in group.files.first { $0.id == id }?.name })
    }

    @Test func findsExactCopiesAndKeepsOne() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let a = try Self.write(fx, "Pictures/a.jpg", Self.pattern(1))
        let b = try Self.write(fx, "Desktop/b.jpg", Self.pattern(1))
        let c = try Self.write(fx, "Desktop/c.jpg", Self.pattern(2))
        let big1 = try Self.write(fx, "Movies/big1.mov", Self.pattern(3, size: 400_000))
        let big2 = try Self.write(fx, "Movies/big2.mov", Self.pattern(3, size: 400_000))
        let index = try await Self.index([
            Self.record(a, added: 10), Self.record(b, added: 20), Self.record(c, added: 5),
            Self.record(big1, added: 1), Self.record(big2, added: 2),
        ])
        let groups = await Self.finder(index).groups(minBytes: 1_000)
        #expect(groups.count == 2)
        let first = try #require(groups.first)
        #expect(first.files.map(\.name) == ["big1.mov", "big2.mov"])
        let group = try #require(groups.last)
        #expect(group.files.map(\.name) == ["a.jpg", "b.jpg"])
        #expect(Self.names(group, [group.keep]) == ["a.jpg"])
        #expect(Self.names(group, group.defaultSelection()) == ["b.jpg"])
        #expect(group.extraBytes == 200_000)
        #expect(group.clones.isEmpty)
    }

    @Test func keepPrefersOrganizedFoldersThenOldest() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let downloaded = try Self.write(fx, "Downloads/x.bin", Self.pattern(1))
        let documents = try Self.write(fx, "Documents/x.bin", Self.pattern(1))
        let pictures = try Self.write(fx, "Pictures/x.bin", Self.pattern(1))
        let tieA = try Self.write(fx, "Documents/a/same.bin", Self.pattern(2))
        let tieB = try Self.write(fx, "Documents/b/same.bin", Self.pattern(2))
        let index = try await Self.index([
            Self.record(downloaded, added: 1), Self.record(documents, added: 5), Self.record(pictures, added: 9),
            Self.record(tieB, added: 3), Self.record(tieA, added: 3),
        ])
        let groups = await Self.finder(index, downloads: fx.path("Downloads")).groups(minBytes: 1_000)
        let x = try #require(groups.first { $0.files.first?.name == "x.bin" })
        #expect(x.files.map(\.path) == [documents, pictures, downloaded])
        #expect(x.keep == x.files[0].id)
        let tie = try #require(groups.first { $0.files.first?.name == "same.bin" })
        #expect(tie.files.first?.path == tieA)
    }

    @Test func differentFilesOfTheSameSizeAreNotDuplicates() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        var changedInTheMiddle = Self.pattern(1)
        changedInTheMiddle[100_000] &+= 1
        let a = try Self.write(fx, "a.bin", Self.pattern(1))
        let b = try Self.write(fx, "b.bin", changedInTheMiddle)
        let c = try Self.write(fx, "c.bin", Self.pattern(9))
        let index = try await Self.index([Self.record(a, added: 1), Self.record(b, added: 2), Self.record(c, added: 3)])
        #expect(await Self.finder(index).groups(minBytes: 1_000).isEmpty)
    }

    @Test func clonesAndHardLinksFreeNothing() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let original = try Self.write(fx, "Pictures/original.jpg", Self.pattern(1))
        let clone = fx.path("Desktop/clone.jpg")
        let link = fx.path("Desktop/link.jpg")
        try fx.dir("Desktop")
        try fx.clone(original, clone)
        try fx.hardLink(original, link)
        let copy = try Self.write(fx, "Documents/copy.jpg", Self.pattern(1))
        let index = try await Self.index([
            Self.record(original, added: 1), Self.record(clone, added: 2), Self.record(link, added: 3),
            Self.record(copy, added: 4),
        ])
        let group = try #require(await Self.finder(index).groups(minBytes: 1_000).first)
        #expect(group.files.first?.name == "original.jpg")
        #expect(Self.names(group, group.clones) == ["clone.jpg", "link.jpg"])
        #expect(Self.names(group, group.defaultSelection()) == ["copy.jpg"])
        #expect(group.extraBytes == 200_000)
    }

    @Test func smallAndCloudOnlyFilesAreSkipped() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let small1 = try Self.write(fx, "s1.bin", Self.pattern(1, size: 500_000))
        let small2 = try Self.write(fx, "s2.bin", Self.pattern(1, size: 500_000))
        let hasher = CountingHasher()
        let index = try await Self.index([
            Self.record(small1, added: 1), Self.record(small2, added: 2),
            Self.record(fx.path("cloud1.mov"), added: 1, bytes: 5_000_000, cloud: true),
            Self.record(fx.path("cloud2.mov"), added: 2, bytes: 5_000_000, cloud: true),
        ])
        #expect(await Self.finder(index, hasher: hasher).groups(minBytes: 1_000_000).isEmpty)
        #expect(hasher.partialReads.isEmpty && hasher.fullReads.isEmpty)
    }

    @Test func filesInCodeProjectsAreSkipped() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let asset = try Self.write(fx, "code/game/Assets/tree.png", Self.pattern(1))
        let build = try Self.write(fx, "code/game/Build/tree.png", Self.pattern(1))
        let mine = try Self.write(fx, "Pictures/tree.png", Self.pattern(1))
        let index = try await Self.index([Self.record(asset, added: 1), Self.record(build, added: 2), Self.record(mine, added: 3)])
        let projects = fx.path("code/game/")
        let groups = await Self.finder(index, isInCodeProject: { $0.hasPrefix(projects) }).groups(minBytes: 1_000)
        #expect(groups.isEmpty)
    }

    @Test func hashesAreReusedUntilAFileChanges() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let a = try Self.write(fx, "a.bin", Self.pattern(1))
        let b = try Self.write(fx, "b.bin", Self.pattern(1))
        let index = try await Self.index([Self.record(a, added: 1), Self.record(b, added: 2)])
        let hasher = CountingHasher()
        let finder = Self.finder(index, hasher: hasher)
        #expect(await finder.groups(minBytes: 1_000).count == 1)
        #expect(hasher.partialReads.count == 2 && hasher.fullReads.count == 2)

        hasher.reset()
        #expect(await finder.groups(minBytes: 1_000).count == 1)
        #expect(hasher.partialReads.isEmpty && hasher.fullReads.isEmpty)

        var changed = Self.pattern(1)
        changed[100_000] &+= 1
        try changed.write(to: URL(fileURLWithPath: b))
        try await index.upsert([Self.record(b, added: 2, modified: 2_000)], generation: await index.beginPass())
        hasher.reset()
        #expect(await finder.groups(minBytes: 1_000).isEmpty)
        #expect(hasher.partialReads == [b] && hasher.fullReads == [b])
    }

    @Test func bigFilesAreHashedOnlyWhenTheyMightMatch() async throws {
        let huge: Int64 = 50_000_000_000
        let hasher = CountingHasher(TableHasher(
            partial: ["/v/one.vmdk": "p1", "/v/two.vmdk": "p2", "/v/three.img": "p3", "/v/four.img": "p3"],
            full: ["/v/three.img": "f3", "/v/four.img": "f3"]))
        let index = try await Self.index([
            Self.record("/v/one.vmdk", added: 1, bytes: huge), Self.record("/v/two.vmdk", added: 2, bytes: huge),
            Self.record("/v/three.img", added: 3, bytes: huge + 1), Self.record("/v/four.img", added: 4, bytes: huge + 1),
        ])
        let groups = await Self.finder(index, hasher: hasher).groups(minBytes: 1_000)
        #expect(groups.map(\.id) == ["f3"])
        #expect(Set(hasher.partialReads).count == 4)
        #expect(Set(hasher.fullReads) == ["/v/three.img", "/v/four.img"])
    }

    @Test func usesOnlyCachedHashesWhilePaused() async throws {
        let hasher = CountingHasher(TableHasher(partial: [:], full: [:]))
        let index = try await Self.index([
            Self.record("/u/cached1.bin", added: 1, bytes: 5_000), Self.record("/u/cached2.bin", added: 2, bytes: 5_000),
            Self.record("/u/new1.bin", added: 1, bytes: 7_000), Self.record("/u/new2.bin", added: 2, bytes: 7_000),
        ])
        for file in await FileIndexTests.all(index) where file.name.hasPrefix("cached") {
            try await index.storeHashes(for: file, partial: "p", full: "f")
        }
        let groups = await Self.finder(index, hasher: hasher, paused: true).groups(minBytes: 1_000)
        #expect(groups.map(\.id) == ["f"])
        #expect(hasher.partialReads.isEmpty && hasher.fullReads.isEmpty)
    }

    @Test func extrasStayWhenTheKeptCopyIsGone() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let a = try Self.write(fx, "a.bin", Self.pattern(1))
        let b = try Self.write(fx, "b.bin", Self.pattern(1))
        let index = try await Self.index([Self.record(a, added: 1), Self.record(b, added: 2)])
        let group = try #require(await Self.finder(index).groups(minBytes: 1_000).first)
        let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        #expect(group.trashable(group.defaultSelection(), exists: exists).map(\.path) == [b])
        try FileManager.default.removeItem(atPath: a)
        #expect(group.trashable(group.defaultSelection(), exists: exists).isEmpty)
    }

    @Test func neverTrashesEveryCopy() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let paths = try (1...3).map { try Self.write(fx, "copy\($0).bin", Self.pattern(1)) }
        let index = try await Self.index(paths.enumerated().map { Self.record($1, added: Double($0)) })
        var group = try #require(await Self.finder(index).groups(minBytes: 1_000).first)
        let everything = Set(group.files.map(\.id))
        let trashed = group.trashable(everything, exists: { _ in true })
        #expect(trashed.count == 2)
        #expect(!trashed.contains { $0.id == group.keep })
        // Keeping another copy moves what's offered with it.
        group.keep = group.files[2].id
        #expect(Self.names(group, group.defaultSelection()) == ["copy1.bin", "copy2.bin"])
        #expect(!group.trashable(everything, exists: { _ in true }).contains { $0.id == group.keep })
    }

    /// A refresh while the page is open keeps what the user chose: the copy they keep and the copies they unticked.
    /// Copies and groups new to the page start with their extras picked.
    @Test func refreshingKeepsTheUsersChoices() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let a1 = try Self.write(fx, "Pictures/a.jpg", Self.pattern(1))
        let a2 = try Self.write(fx, "Desktop/a.jpg", Self.pattern(1))
        let a3 = try Self.write(fx, "Documents/a.jpg", Self.pattern(1))
        let index = try await Self.index([Self.record(a1, added: 1), Self.record(a2, added: 2), Self.record(a3, added: 3)])
        let finder = Self.finder(index)
        var groups = await finder.groups(minBytes: 1_000)
        func id(_ path: String) -> Int64 { groups.flatMap(\.files).first { $0.path == path }!.id }
        // The user keeps the Desktop copy instead, and unticks the Documents one.
        groups[0].keep = id(a2)
        var selection: Set<Int64> = [id(a1)]

        let a4 = try Self.write(fx, "Movies/a.jpg", Self.pattern(1))
        let b1 = try Self.write(fx, "Pictures/b.jpg", Self.pattern(2))
        let b2 = try Self.write(fx, "Desktop/b.jpg", Self.pattern(2))
        try await index.upsert([Self.record(a4, added: 4), Self.record(b1, added: 5), Self.record(b2, added: 6)],
                               generation: await index.beginPass())
        let fresh = await finder.groups(minBytes: 1_000)
        (groups, selection) = DuplicateGroup.merge(fresh, keeping: groups, selection: selection)

        let all = groups.flatMap(\.files)
        func name(_ ids: Set<Int64>) -> Set<String> { Set(all.filter { ids.contains($0.id) }.map(\.path)) }
        let a = try #require(groups.first { $0.files.contains { $0.path == a1 } })
        #expect(a.files.first { $0.id == a.keep }?.path == a2)
        #expect(name(selection) == [a1, a4, b2])
    }
}

