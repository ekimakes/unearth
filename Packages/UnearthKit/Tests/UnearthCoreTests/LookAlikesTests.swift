import Foundation
import Synchronization
import Testing
@testable import UnearthCore

/// Each print is one number, a photo's place on a line; the distance between prints is how far apart they are.
struct LinePrints: FeaturePrintComparing {
    static func print(_ position: Float) -> Data { withUnsafeBytes(of: position) { Data($0) } }

    func distance(_ a: Data, _ b: Data) -> Float? {
        guard a.count == 4, b.count == 4 else { return nil }
        return abs(a.withUnsafeBytes { $0.loadUnaligned(as: Float.self) } - b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
    }
}

struct TableScorer: ShotScoring {
    let scores: [String: Float]
    func score(imageAt path: String) async -> Float? { scores[(path as NSString).lastPathComponent] }
}

/// Scores from a table and counts how many photos it was asked about.
final class CountingScorer: ShotScoring {
    private let table: TableScorer
    private let asked = Mutex(0)
    init(_ scores: [String: Float]) { table = TableScorer(scores: scores) }
    var count: Int { asked.withLock { $0 } }

    func score(imageAt path: String) async -> Float? {
        asked.withLock { $0 += 1 }
        return await table.score(imageAt: path)
    }
}

struct LookAlikesTests {
    static let start = Date(timeIntervalSince1970: 1_750_000_000)

    struct Photo {
        let path: String
        var taken: TimeInterval = 0
        var position: Float?
        var bytes: Int64 = 3_000_000
    }

    static func finder(_ photos: [Photo], scores: [String: Float] = [:],
                       isInCodeProject: @escaping @Sendable (String) -> Bool = { _ in false }) async throws -> LookAlikeFinder {
        LookAlikeFinder(index: try await Self.index(photos), comparer: LinePrints(), scorer: TableScorer(scores: scores),
                        isInCodeProject: isInCodeProject, power: FakePower(paused: false))
    }

    static func index(_ photos: [Photo]) async throws -> FileIndex {
        let index = try FileIndex.inMemory()
        let records = photos.map { photo in
            let name = (photo.path as NSString).lastPathComponent
            let parent = (photo.path as NSString).deletingLastPathComponent
            return IndexedFileRecord(
                path: photo.path, name: name, parent: parent, folder: (parent as NSString).lastPathComponent, kind: .image,
                fileExtension: FileClassifier.fileExtension(name), bytes: photo.bytes,
                created: start.addingTimeInterval(photo.taken), modified: start, added: start, source: nil, isCloudOnly: false)
        }
        try await index.upsert(records, generation: await index.beginPass())
        for file in await FileIndexTests.all(index) {
            guard let position = photos.first(where: { $0.path == file.path })?.position else { continue }
            try await index.setPrint(for: file, print: LinePrints.print(position))
        }
        return index
    }

    static func names(_ groups: [LookAlikeGroup]) -> [[String]] {
        groups.map { $0.files.map(\.name) }
    }

    @Test func burstsGroupTogether() async throws {
        let groups = try await Self.finder([
            Photo(path: "/u/Pictures/IMG_1.jpg", taken: 0, position: 0),
            Photo(path: "/u/Pictures/IMG_2.jpg", taken: 2, position: 0.1),
            Photo(path: "/u/Pictures/IMG_3.jpg", taken: 4, position: 0.2),
            Photo(path: "/u/Pictures/IMG_4.jpg", taken: 9, position: 5),
        ]).groups()
        #expect(Self.names(groups) == [["IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg"]])
    }

    @Test func pairsOfTheSamePhotoGroup() async throws {
        let groups = try await Self.finder([
            Photo(path: "/u/Pictures/IMG_1.HEIC", taken: 0),
            Photo(path: "/u/Pictures/IMG_1.jpg", taken: 86_400),
            Photo(path: "/u/Pictures/IMG_2.heic", taken: 0),
            Photo(path: "/u/Desktop/IMG_2.jpeg", taken: 86_400),
        ]).groups()
        #expect(Self.names(groups) == [["IMG_1.HEIC", "IMG_1.jpg"]])
    }

    @Test func editsGroupWithTheirOriginal() async throws {
        let year: TimeInterval = 365 * 86_400
        let groups = try await Self.finder([
            Photo(path: "/u/Pictures/IMG_7.jpg", taken: 0, position: 0),
            Photo(path: "/u/Pictures/IMG_7 edited.jpg", taken: year, position: 0.2),
            Photo(path: "/u/Pictures/IMG_70.jpg", taken: 2 * year, position: 0.1),
            Photo(path: "/u/Pictures/IMG_9041.jpg", taken: 3 * year, position: 7),
            Photo(path: "/u/Pictures/IMG_E9041.jpg", taken: 4 * year, position: 7.1),
        ]).groups()
        #expect(Set(groups.map { Set($0.files.map(\.name)) }) == [
            ["IMG_7.jpg", "IMG_7 edited.jpg"], ["IMG_9041.jpg", "IMG_E9041.jpg"],
        ])
    }

    @Test func differentPhotosStayApart() async throws {
        let groups = try await Self.finder([
            Photo(path: "/u/Pictures/a.jpg", taken: 0, position: 0),
            Photo(path: "/u/Pictures/b.jpg", taken: 1, position: 3),
        ]).groups()
        #expect(groups.isEmpty)
    }

    @Test func photosFarApartInTimeStayApart() async throws {
        let groups = try await Self.finder([
            Photo(path: "/u/Pictures/beach.jpg", taken: 0, position: 0),
            Photo(path: "/u/Pictures/sea.jpg", taken: 86_400, position: 0.1),
        ]).groups()
        #expect(groups.isEmpty)
    }

    @Test func bestShotIsTheHighestScored() async throws {
        let scored = try await Self.finder([
            Photo(path: "/u/Pictures/a.jpg", taken: 0, position: 0),
            Photo(path: "/u/Pictures/b.jpg", taken: 1, position: 0.1),
            Photo(path: "/u/Pictures/c.jpg", taken: 2, position: 0.2),
        ], scores: ["a.jpg": 0.1, "b.jpg": 0.8, "c.jpg": 0.5]).groups()
        let group = try #require(scored.first)
        #expect(group.files.first { $0.id == group.best }?.name == "b.jpg")

        let unscored = try await Self.finder([
            Photo(path: "/u/Pictures/a.jpg", taken: 0, position: 0, bytes: 1_000_000),
            Photo(path: "/u/Pictures/b.jpg", taken: 1, position: 0.1, bytes: 4_000_000),
        ]).groups()
        let fallback = try #require(unscored.first)
        #expect(fallback.files.first { $0.id == fallback.best }?.name == "b.jpg")
    }

    /// A photo is scored once: the score is kept in the index for the next look, and the next launch.
    @Test func scoresAreKeptBetweenLooks() async throws {
        let burst = [Photo(path: "/u/Pictures/a.jpg", taken: 0, position: 0), Photo(path: "/u/Pictures/b.jpg", taken: 1, position: 0.1)]
        let index = try await Self.index(burst)
        let scorer = CountingScorer(["a.jpg": 0.2, "b.jpg": 0.9])
        func finder() -> LookAlikeFinder {
            LookAlikeFinder(index: index, comparer: LinePrints(), scorer: scorer, isInCodeProject: { _ in false },
                            power: FakePower(paused: false))
        }
        let first = try #require(await finder().groups().first)
        #expect(scorer.count == 2)
        let again = try #require(await finder().groups().first)
        #expect(scorer.count == 2)
        #expect(again.best == first.best)
        #expect(again.files.first { $0.id == again.best }?.name == "b.jpg")
    }

    /// Scoring is background work: on battery, in Low Power Mode or when hot, the largest photo stands in.
    @Test func scoringWaitsWhileThePowerRulesSayWait() async throws {
        let index = try await Self.index([
            Photo(path: "/u/Pictures/a.jpg", taken: 0, position: 0, bytes: 1_000_000),
            Photo(path: "/u/Pictures/b.jpg", taken: 1, position: 0.1, bytes: 4_000_000),
        ])
        let scorer = CountingScorer(["a.jpg": 0.9, "b.jpg": 0.1])
        let group = try #require(await LookAlikeFinder(index: index, comparer: LinePrints(), scorer: scorer,
                                                       isInCodeProject: { _ in false }, power: FakePower(paused: true)).groups().first)
        #expect(scorer.count == 0)
        #expect(group.files.first { $0.id == group.best }?.name == "b.jpg")
    }

    @Test func newestGroupsComeFirst() async throws {
        let groups = try await Self.finder([
            Photo(path: "/u/Pictures/old1.jpg", taken: 0, position: 0),
            Photo(path: "/u/Pictures/old2.jpg", taken: 1, position: 0.1),
            Photo(path: "/u/Pictures/new1.jpg", taken: 86_400, position: 4),
            Photo(path: "/u/Pictures/new2.jpg", taken: 86_401, position: 4.1),
        ]).groups()
        #expect(Self.names(groups) == [["new1.jpg", "new2.jpg"], ["old1.jpg", "old2.jpg"]])
    }

    /// Icons, exports and other graphics downloaded together aren't a burst.
    @Test func graphicsAreNotPhotos() async throws {
        let groups = try await Self.finder([
            Photo(path: "/u/Downloads/icon-1.png", taken: 0, position: 0),
            Photo(path: "/u/Downloads/icon-2.png", taken: 1, position: 0.1),
            Photo(path: "/u/Downloads/banner.gif", taken: 2, position: 0.1),
            Photo(path: "/u/Downloads/hero.webp", taken: 3, position: 0.2),
        ]).groups()
        #expect(groups.isEmpty)
        #expect(FileKinds.photoExtensions.isSuperset(of: ["heic", "jpg", "jpeg", "dng"]))
        #expect(!FileKinds.photoExtensions.contains("png"))
    }

    @Test func codeProjectImagesAreSkipped() async throws {
        let groups = try await Self.finder([
            Photo(path: "/u/code/game/Assets/frame1.jpg", taken: 0, position: 0),
            Photo(path: "/u/code/game/Assets/frame2.jpg", taken: 1, position: 0.1),
        ], isInCodeProject: { $0.hasPrefix("/u/code/game/") }).groups()
        #expect(groups.isEmpty)
    }
}
