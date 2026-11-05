import Foundation
import Testing
@testable import UnearthCore

struct IndexerTests {
    static func indexed(_ fx: Fixture, roots: [String], excluding: [String] = []) async throws -> (FileIndex, [IndexedFile]) {
        let index = try FileIndex.inMemory()
        _ = try await Indexer(index: index, excludedPaths: excluding.map(fx.path)).index(roots: roots.map(fx.path))
        return (index, await index.files(kind: nil, source: nil, parent: nil, sort: .name, limit: 100_000, offset: 0))
    }

    static func relative(_ fx: Fixture, _ files: [IndexedFile]) -> Set<String> {
        Set(files.map { String($0.path.dropFirst(fx.root.count + 1)) })
    }

    @Test func indexesFilesSkippingHiddenAndNodeModules() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        for path in ["Documents/a.pdf", "Documents/.hidden.txt", "Documents/.git/config", "Documents/.cache/blob",
                     "Documents/proj/node_modules/x/index.js", "Documents/proj/main.swift"] {
            try fx.file(path, bytes: 100)
        }
        try fx.symlink("Documents/link.pdf", to: fx.path("Documents/a.pdf"))
        let (_, files) = try await Self.indexed(fx, roots: ["Documents"])
        #expect(Self.relative(fx, files) == ["Documents/a.pdf", "Documents/proj/main.swift"])
        let pdf = try #require(files.first { $0.name == "a.pdf" })
        #expect(pdf.kind == .document && pdf.fileExtension == "pdf" && pdf.parent == fx.path("Documents"))
    }

    @Test func packagesAreSingleItems() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("Applications/Tool.app/Contents/MacOS/tool", bytes: 50_000)
        try fx.file("Applications/Tool.app/Contents/Info.plist", bytes: 1_000)
        try fx.file("Documents/Talk.key/Data/image.png", bytes: 20_000)
        try fx.file("Documents/Talk.key/Index.zip", bytes: 4_000)
        let (_, files) = try await Self.indexed(fx, roots: ["Applications", "Documents"])
        #expect(Self.relative(fx, files) == ["Applications/Tool.app", "Documents/Talk.key"])
        let app = try #require(files.first { $0.name == "Tool.app" })
        #expect(app.kind == .app && app.bytes >= 51_000)
        #expect(files.first { $0.name == "Talk.key" }?.kind == .document)
    }

    /// Found on a real Mac: Cinema 4D keeps ~39,000 loose resource files next to its app in /Applications.
    @Test func applicationsFoldersListOnlyApps() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("Applications/Tool.app/Contents/MacOS/tool", bytes: 1_000)
        try fx.file("Applications/Maxon Cinema 4D 2024/Cinema 4D.app/Contents/MacOS/c4d", bytes: 1_000)
        try fx.file("Applications/Maxon Cinema 4D 2024/resource/modules/x/strings.str", bytes: 100)
        try fx.file("Applications/Maxon Cinema 4D 2024/readme.pdf", bytes: 100)
        try fx.file("Documents/notes.pdf", bytes: 100)
        let (_, files) = try await Self.indexed(fx, roots: ["Applications", "Documents"])
        #expect(Self.relative(fx, files) == [
            "Applications/Tool.app", "Applications/Maxon Cinema 4D 2024/Cinema 4D.app", "Documents/notes.pdf",
        ])
    }

    /// Found on a real Mac: an app's ~11,000 cache files inside Movies, and generated folders in projects.
    @Test func skipsCachesAndDependencyFolders() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        for path in ["Movies/CapCut/User Data/Cache/effect/1.png", "Movies/CapCut/User Data/Caches/x.bin",
                     "Documents/app/Pods/Alamofire/a.swift", "Documents/app/DerivedData/b.o", "Documents/py/__pycache__/c.pyc",
                     "Documents/py/venv/lib/python3.12/site-packages/d.py", "Documents/app/main.swift", "Movies/CapCut/Draft.mp4"] {
            try fx.file(path, bytes: 100)
        }
        let (_, files) = try await Self.indexed(fx, roots: ["Movies", "Documents"])
        #expect(Self.relative(fx, files) == ["Movies/CapCut/Draft.mp4", "Documents/app/main.swift"])
    }

    @Test func photosLibraryIsSkipped() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("Pictures/Photos Library.photoslibrary/originals/0/IMG_1.heic", bytes: 10_000)
        try fx.file("Pictures/me.jpg", bytes: 10_000)
        let (_, files) = try await Self.indexed(fx, roots: ["Pictures"])
        #expect(files.map(\.name) == ["me.jpg"])
    }

    @Test func excludedFoldersAreSkipped() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("home/Library/Caches/x.db", bytes: 100)
        try fx.file("home/notes.txt", bytes: 100)
        let (_, files) = try await Self.indexed(fx, roots: ["home"], excluding: ["home/Library"])
        #expect(files.map(\.name) == ["notes.txt"])
    }

    /// iCloud placeholders are listed with their real size but never read.
    @Test func marksDatalessFilesCloudOnly() async throws {
        let reader = FakeDirectoryReader(listings: ["/r": [
            DirectoryEntry(name: "cloud.pdf", kind: .file, allocatedSize: 0, logicalSize: 5_000_000, isDataless: true),
            .fakeFile("local.pdf", bytes: 4_096),
        ]])
        let index = try FileIndex.inMemory()
        _ = try await Indexer(index: index, reader: reader).index(roots: ["/r"])
        let files = await index.files(kind: nil, source: nil, parent: nil, sort: .name, limit: 10, offset: 0)
        #expect(files.map(\.name) == ["cloud.pdf", "local.pdf"])
        #expect(files[0].isCloudOnly && files[0].bytes == 5_000_000)
        #expect(!files[1].isCloudOnly)
    }

    @Test func refreshRemovesVanishedFiles() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        for path in ["Documents/a.pdf", "Documents/b.pdf", "Documents/sub/c.pdf", "Documents/sub/deeper/d.pdf", "Documents/keep/k.pdf"] {
            try fx.file(path, bytes: 100)
        }
        let index = try FileIndex.inMemory()
        let indexer = Indexer(index: index)
        _ = try await indexer.index(roots: [fx.path("Documents")])
        try FileManager.default.removeItem(atPath: fx.path("Documents/b.pdf"))
        try FileManager.default.removeItem(atPath: fx.path("Documents/sub"))
        try fx.file("Documents/e.pdf", bytes: 100)
        try fx.file("Moved/new/f.pdf", bytes: 100)
        try FileManager.default.moveItem(atPath: fx.path("Moved/new"), toPath: fx.path("Documents/new"))
        try await indexer.refresh(directories: [fx.path("Documents")])
        let files = await index.files(kind: nil, source: nil, parent: nil, sort: .name, limit: 100, offset: 0)
        #expect(Self.relative(fx, files) == ["Documents/a.pdf", "Documents/e.pdf", "Documents/keep/k.pdf", "Documents/new/f.pdf"])
    }

    /// A folder that can't be read right now isn't a folder that's gone.
    @Test func refreshKeepsFilesOfAFolderItCantRead() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("Documents/locked/x.pdf", bytes: 100)
        try fx.file("Documents/open/y.pdf", bytes: 100)
        let index = try FileIndex.inMemory()
        let indexer = Indexer(index: index)
        _ = try await indexer.index(roots: [fx.path("Documents")])
        chmod(fx.path("Documents/locked"), 0o000)
        defer { chmod(fx.path("Documents/locked"), 0o755) }
        try await indexer.refresh(directories: [fx.path("Documents/locked")])
        #expect(await index.count() == 2)

        // A folder moved in with an unreadable part still has its readable files indexed.
        for name in ["a", "b", "c", "d"] { try fx.file("Moved/tree/\(name)/\(name).pdf", bytes: 100) }
        chmod(fx.path("Moved/tree/b"), 0o000)
        defer { chmod(fx.path("Documents/tree/b"), 0o755) }
        try FileManager.default.moveItem(atPath: fx.path("Moved/tree"), toPath: fx.path("Documents/tree"))
        try await indexer.refresh(directories: [fx.path("Documents")])
        let names = Set(await index.files(kind: nil, source: nil, parent: nil, sort: .name, limit: 10, offset: 0).map(\.name))
        #expect(names == ["x.pdf", "y.pdf", "a.pdf", "c.pdf", "d.pdf"])
    }

    /// Found by review: index passes overlapped (a full pass and a refresh, a folder and its parent) and
    /// deleted rows of files still on disk, because a late write from an older pass lowered `seen`.
    @Test func overlappingPassesKeepEveryFile() async throws {
        for _ in 0..<4 {
            let fx = try Fixture()
            defer { fx.remove() }
            for n in 0..<600 { try fx.file("Documents/f\(n).txt", bytes: 10) }
            for sub in 0..<6 { for n in 0..<100 { try fx.file("Documents/s\(sub)/g\(n).txt", bytes: 10) } }
            let index = try FileIndex.inMemory()
            let indexer = Indexer(index: index)
            _ = try await indexer.index(roots: [fx.path("Documents")])
            async let refresh = indexer.refresh(directories: [fx.path("Documents")])
            async let pass = indexer.index(roots: [fx.path("Documents")])
            _ = try await (refresh, pass)
            #expect(await index.count() == 1_200)
            async let child = indexer.refresh(directories: (0..<6).map { fx.path("Documents/s\($0)") })
            async let parent = indexer.refresh(directories: [fx.path("Documents")])
            _ = try await (child, parent)
            #expect(await index.count() == 1_200)
        }
    }

    /// A full pass, like a refresh, keeps the files of a folder it can't read right now.
    @Test func fullPassKeepsFilesOfAFolderItCantRead() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("Documents/locked/x.pdf", bytes: 100)
        try fx.file("Documents/open/y.pdf", bytes: 100)
        let index = try FileIndex.inMemory()
        let indexer = Indexer(index: index)
        _ = try await indexer.index(roots: [fx.path("Documents")])
        chmod(fx.path("Documents/locked"), 0o000)
        defer { chmod(fx.path("Documents/locked"), 0o755) }
        _ = try await indexer.index(roots: [fx.path("Documents")])
        #expect(await index.count() == 2)
    }

    /// iCloud Drive and other synced folders live under ~/Library, which is otherwise left out.
    @Test func addedFoldersInsideExcludedOnesAreIndexed() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let drive = "home/Library/Mobile Documents/com~apple~CloudDocs"
        try fx.file(drive + "/top.pdf", bytes: 100)
        try fx.file(drive + "/Work/deep.pdf", bytes: 100)
        try fx.file("home/Library/Caches/x.db", bytes: 100)
        let index = try FileIndex.inMemory()
        let indexer = Indexer(index: index, excludedPaths: [fx.path("home/Library")])
        _ = try await indexer.index(roots: [fx.path(drive), fx.path("home")])
        try fx.file(drive + "/Work/new.pdf", bytes: 100)
        try await indexer.refresh(directories: [fx.path(drive + "/Work")])
        let names = Set(await index.files(kind: nil, source: nil, parent: nil, sort: .name, limit: 10, offset: 0).map(\.name))
        #expect(names == ["top.pdf", "deep.pdf", "new.pdf"])
    }

    @Test func refreshReportsWhatChanged() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("Documents/a.pdf", bytes: 100)
        try fx.file("Documents/sub/b.pdf", bytes: 100)
        try fx.file("Documents/.git/objects/x", bytes: 10)
        let index = try FileIndex.inMemory()
        let indexer = Indexer(index: index)
        _ = try await indexer.index(roots: [fx.path("Documents")])
        #expect(try await indexer.refresh(directories: [fx.path("Documents")]) == 0)
        #expect(try await indexer.refresh(directories: [fx.path("Documents/.git/objects")]) == 0)
        try fx.file("Documents/c.pdf", bytes: 100)
        #expect(try await indexer.refresh(directories: [fx.path("Documents")]) == 1)
        try FileManager.default.removeItem(atPath: fx.path("Documents/a.pdf"))
        #expect(try await indexer.refresh(directories: [fx.path("Documents")]) == 1)
    }

    @Test func readsSourcesAndScreenshotFlags() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let report = try fx.file("Downloads/report.pdf", bytes: 100)
        try DownloadSourceTests.setMetadata(report, "kMDItemWhereFroms", ["https://files.oaiusercontent.com/f/report.pdf", "https://chatgpt.com/"])
        let shot = try fx.file("Desktop/shot.png", bytes: 100)
        try DownloadSourceTests.setMetadata(shot, "kMDItemIsScreenCapture", true)
        try fx.file("Desktop/picture.png", bytes: 100)
        let (index, files) = try await Self.indexed(fx, roots: ["Downloads", "Desktop"])
        #expect(files.first { $0.name == "report.pdf" }?.source == "ChatGPT")
        #expect(files.first { $0.name == "shot.png" }?.kind == .screenshot)
        #expect(files.first { $0.name == "picture.png" }?.kind == .image)
        #expect(await index.sourceSummaries() == [SourceSummary(source: "ChatGPT", count: 1, bytes: 100)])
    }

    @Test func usesTheDateFilesArrived() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let file = try fx.file("Downloads/x.zip", bytes: 100, modified: Date(timeIntervalSince1970: 1_000_000))
        let added = try #require(try URL(fileURLWithPath: file).resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate)
        let (_, files) = try await Self.indexed(fx, roots: ["Downloads"])
        let row = try #require(files.first)
        #expect(abs(row.added.timeIntervalSince(added)) < 1)
        #expect(row.modified == Date(timeIntervalSince1970: 1_000_000))
    }

    @Test func indexes20kFilesInBatches() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        for folder in 0..<20 {
            let directory = try fx.dir("Documents/f\(folder)")
            for file in 0..<1_000 {
                FileManager.default.createFile(atPath: directory + "/n\(file).txt", contents: nil)
            }
        }
        let index = try FileIndex.inMemory()
        let reports = Reports()
        let clock = ContinuousClock()
        let start = clock.now
        let stats = try await Indexer(index: index).index(roots: [fx.path("Documents")]) { reports.add($0) }
        #expect(clock.now - start < .seconds(10))
        #expect(stats.files == 20_000)
        #expect(await index.count() == 20_000)
        #expect(reports.values.count > 1)
        #expect(reports.values.last == 20_000)
    }
}

/// Collects progress callbacks, which arrive from the indexer's actor.
final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []
    func add(_ value: Int) { lock.withLock { stored.append(value) } }
    var values: [Int] { lock.withLock { stored } }
}
