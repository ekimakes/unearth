import Foundation
import Testing
@testable import UnearthCore

struct CollectionsWorkTests {
    static let scan = UUID()

    static func state(scan: UUID? = Self.scan, duplicates: Int = 1, photos: Int = 1, prints: Int = 0,
                      settings: CollectionSettings = CollectionSettings()) -> CollectionsState {
        CollectionsState(scan: scan, duplicates: IndexFingerprint(count: duplicates, maxID: 9, latest: 1_000, prints: 0),
                         photos: IndexFingerprint(count: photos, maxID: 9, latest: 1_000, prints: prints), settings: settings)
    }

    @Test func theFirstLookDoesEverything() {
        #expect(CollectionsWork.needed(since: nil, now: Self.state()) == CollectionsWork(apps: true, duplicates: true, lookAlikes: true))
    }

    @Test func nothingHeavyIsRedoneWhenNothingChanged() {
        #expect(CollectionsWork.needed(since: Self.state(), now: Self.state()) == CollectionsWork(apps: false, duplicates: false, lookAlikes: false))
    }

    @Test func aNewScanRedoesTheApps() {
        #expect(CollectionsWork.needed(since: Self.state(), now: Self.state(scan: UUID()))
            == CollectionsWork(apps: true, duplicates: false, lookAlikes: false))
    }

    @Test func changedCandidatesRedoDuplicates() {
        #expect(CollectionsWork.needed(since: Self.state(), now: Self.state(duplicates: 2))
            == CollectionsWork(apps: false, duplicates: true, lookAlikes: false))
    }

    @Test func newPhotosOrPrintsRedoLookAlikes() {
        #expect(CollectionsWork.needed(since: Self.state(), now: Self.state(prints: 5)).lookAlikes)
        #expect(CollectionsWork.needed(since: Self.state(), now: Self.state(photos: 2)).lookAlikes)
    }

    @Test func settingsRedoWhatTheyAffect() {
        var apps = CollectionSettings()
        apps.unusedAppDays = 30
        #expect(CollectionsWork.needed(since: Self.state(), now: Self.state(settings: apps))
            == CollectionsWork(apps: true, duplicates: false, lookAlikes: false))
        var duplicates = CollectionSettings()
        duplicates.duplicateMinBytes = 10_000_000
        #expect(CollectionsWork.needed(since: Self.state(), now: Self.state(settings: duplicates))
            == CollectionsWork(apps: false, duplicates: true, lookAlikes: false))
    }

    @Test func fingerprintsFollowTheIndex() async throws {
        let index = try FileIndex.inMemory()
        try await index.upsert([FileIndexTests.record("/u/Pictures/a.jpg", kind: .image, bytes: 50_000)],
                               generation: await index.beginPass())
        let duplicates = await index.duplicatesFingerprint(minBytes: 1_000)
        let photos = await index.lookAlikesFingerprint()
        // A small file changes neither; a big one changes the duplicates' fingerprint.
        try await index.upsert([FileIndexTests.record("/u/Documents/tiny.txt", bytes: 10)], generation: await index.beginPass())
        #expect(await index.duplicatesFingerprint(minBytes: 1_000) == duplicates)
        #expect(await index.lookAlikesFingerprint() == photos)
        try await index.upsert([FileIndexTests.record("/u/Movies/big.mov", kind: .video, bytes: 5_000_000)],
                               generation: await index.beginPass())
        #expect(await index.duplicatesFingerprint(minBytes: 1_000) != duplicates)
        #expect(await index.lookAlikesFingerprint() == photos)
        // A photo's new print changes the look-alikes' fingerprint, and not the duplicates'.
        let withBig = await index.duplicatesFingerprint(minBytes: 1_000)
        let photo = try #require(await FileIndexTests.all(index).first { $0.name == "a.jpg" })
        try await index.setPrint(for: photo, print: Data([1, 2, 3, 4]))
        #expect(await index.lookAlikesFingerprint() != photos)
        #expect(await index.duplicatesFingerprint(minBytes: 1_000) == withBig)
    }
}
