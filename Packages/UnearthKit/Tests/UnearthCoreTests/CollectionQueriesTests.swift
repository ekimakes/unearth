import Foundation
import Testing
@testable import UnearthCore

struct CollectionQueriesTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    static func record(
        _ path: String, kind: FileKind = .document, bytes: Int64 = 1_000, added: Double = 1, modified: Double? = nil,
        created: Double? = nil, cloud: Bool = false
    ) -> IndexedFileRecord {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        return IndexedFileRecord(
            path: path, name: name, parent: parent, folder: (parent as NSString).lastPathComponent, kind: kind,
            fileExtension: FileClassifier.fileExtension(name), bytes: bytes, created: created.map(daysAgo),
            modified: daysAgo(modified ?? added), added: daysAgo(added), source: nil, isCloudOnly: cloud)
    }

    static func queries(_ records: [IndexedFileRecord], lastUsed: [String: Double] = [:],
                        settings: CollectionSettings = CollectionSettings()) async throws -> CollectionQueries {
        let index = try FileIndex.inMemory()
        try await index.upsert(records, generation: await index.beginPass())
        let opened = lastUsed.mapValues(daysAgo)
        return CollectionQueries(index: index, downloads: "/u/Downloads", settings: settings, now: now,
                                 lastUsed: { opened[$0] })
    }

    static func names(_ files: [IndexedFile]) -> [String] { files.map(\.name) }

    @Test func forgottenDownloadsUseLastOpenedOrAdded() async throws {
        let queries = try await Self.queries([
            Self.record("/u/Downloads/old.pdf", added: 200),
            Self.record("/u/Downloads/opened.pdf", added: 200),
            Self.record("/u/Downloads/opened long ago.pdf", added: 5),
            Self.record("/u/Downloads/new.pdf", added: 5),
            Self.record("/u/Downloads/setup.dmg", added: 200),
            Self.record("/u/Downloads/sub/deep.pdf", added: 200),
            Self.record("/u/Documents/old.pdf", added: 200),
        ], lastUsed: ["/u/Downloads/opened.pdf": 10, "/u/Downloads/opened long ago.pdf": 120])
        let files = await queries.files(.forgottenDownloads)
        #expect(Set(Self.names(files)) == ["old.pdf", "opened long ago.pdf", "deep.pdf"])
        #expect(files.allSatisfy { $0.parent.hasPrefix("/u/Downloads") })
    }

    @Test func oldInstallersAreInstallerFilesInDownloads() async throws {
        let queries = try await Self.queries([
            Self.record("/u/Downloads/Small.dmg", bytes: 1_000),
            Self.record("/u/Downloads/Tool.PKG", bytes: 9_000),
            Self.record("/u/Downloads/Xcode.xip", bytes: 5_000),
            Self.record("/u/Downloads/Disc.iso", bytes: 3_000),
            Self.record("/u/Downloads/Bundle.mpkg", bytes: 2_000),
            Self.record("/u/Downloads/notes.txt", bytes: 50_000),
            Self.record("/u/Documents/Kept.dmg", bytes: 7_000),
        ])
        let files = await queries.files(.oldInstallers)
        #expect(Self.names(files) == ["Tool.PKG", "Xcode.xip", "Disc.iso", "Bundle.mpkg", "Small.dmg"])
    }

    @Test func oldScreenshotsUseWhenTheyWereTaken() async throws {
        let queries = try await Self.queries([
            Self.record("/u/Desktop/filed away.png", kind: .screenshot, added: 2, created: 60),
            Self.record("/u/Desktop/no creation date.png", kind: .screenshot, added: 40),
            Self.record("/u/Desktop/recent.png", kind: .screenshot, added: 10, created: 10),
            Self.record("/u/Pictures/old photo.jpg", kind: .image, added: 100, created: 100),
        ])
        let files = await queries.files(.oldScreenshots)
        #expect(Set(Self.names(files)) == ["filed away.png", "no creation date.png"])
    }

    @Test func bigOldVideosNeedSizeAndAge() async throws {
        let big: Int64 = 600_000_000
        let queries = try await Self.queries([
            Self.record("/u/Movies/old.mov", kind: .video, bytes: big, added: 400, modified: 300),
            Self.record("/u/Movies/watched.mov", kind: .video, bytes: big, added: 400, modified: 300),
            Self.record("/u/Movies/small.mov", kind: .video, bytes: 100_000_000, added: 400, modified: 300),
            Self.record("/u/Movies/new.mov", kind: .video, bytes: big, added: 10, modified: 10),
            Self.record("/u/Movies/opened long ago.mov", kind: .video, bytes: big + 1, added: 20, modified: 20),
            Self.record("/u/Documents/huge.zip", kind: .archive, bytes: big, added: 400, modified: 300),
        ], lastUsed: ["/u/Movies/watched.mov": 10, "/u/Movies/opened long ago.mov": 200])
        let files = await queries.files(.bigOldVideos)
        #expect(Self.names(files) == ["opened long ago.mov", "old.mov"])
    }

    @Test func cloudOnlyFilesAreNeverOffered() async throws {
        let queries = try await Self.queries([
            Self.record("/u/Downloads/in iCloud.pdf", added: 200, cloud: true),
            Self.record("/u/Downloads/in iCloud.dmg", added: 200, cloud: true),
            Self.record("/u/Desktop/in iCloud.png", kind: .screenshot, added: 60, cloud: true),
            Self.record("/u/Movies/in iCloud.mov", kind: .video, bytes: 600_000_000, added: 400, cloud: true),
        ])
        for kind in [CollectionKind.forgottenDownloads, .oldInstallers, .oldScreenshots, .bigOldVideos] {
            #expect(await queries.files(kind).isEmpty, "\(kind)")
        }
    }

    @Test func itemsCarryTheCollectionsExplanation() async throws {
        let queries = try await Self.queries([Self.record("/u/Downloads/old.pdf", bytes: 5_000, added: 200)])
        let file = try #require(await queries.files(.forgottenDownloads).first)
        let item = CollectionKind.forgottenDownloads.item(for: file, onDiskBytes: 4_096)
        #expect(item.ruleID == "collection-forgottenDownloads")
        #expect(item.section == .manual)
        #expect(item.group == "Forgotten downloads")
        #expect(item.title == "old.pdf")
        #expect(item.paths == ["/u/Downloads/old.pdf"])
        #expect(item.bytes == 4_096)
        #expect(item.safety == .review)
        #expect(item.action == .trash)
        #expect(item.explanation == CollectionKind.forgottenDownloads.explanation)
        #expect(!item.isSelectableByDefault)
        for kind in CollectionKind.allCases {
            #expect(!kind.title.isEmpty && !kind.explanation.what.isEmpty && !kind.explanation.safeToDelete.isEmpty)
        }
        #expect(CollectionKind.allCases.map(\.title) == [
            "Duplicates", "Look-alike photos", "Forgotten downloads", "Old installers", "Old screenshots",
            "Big old videos", "Unused apps",
        ])
    }

    @Test func thresholdsComeFromSettings() async throws {
        var settings = CollectionSettings()
        #expect(settings.forgottenDownloadDays == 90 && settings.screenshotDays == 30 && settings.unusedAppDays == 90)
        #expect(settings.bigVideoBytes == 500_000_000 && settings.bigVideoDays == 182 && settings.duplicateMinBytes == 1_000_000)
        settings.screenshotDays = 7
        let queries = try await Self.queries([Self.record("/u/Desktop/week old.png", kind: .screenshot, added: 8)],
                                             settings: settings)
        #expect(Self.names(await queries.files(.oldScreenshots)) == ["week old.png"])
    }
}
