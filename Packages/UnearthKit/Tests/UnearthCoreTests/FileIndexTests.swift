import Foundation
import Testing
@testable import UnearthCore

struct FileIndexTests {
    static func record(
        _ path: String, kind: FileKind = .document, bytes: Int64 = 100, added: Double = 1_000, modified: Double = 1_000,
        source: String? = nil, cloud: Bool = false
    ) -> IndexedFileRecord {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        return IndexedFileRecord(
            path: path, name: name, parent: parent, folder: (parent as NSString).lastPathComponent, kind: kind,
            fileExtension: FileClassifier.fileExtension(name), bytes: bytes, created: nil,
            modified: Date(timeIntervalSince1970: modified), added: Date(timeIntervalSince1970: added), source: source,
            isCloudOnly: cloud)
    }

    static func all(_ index: FileIndex, kind: FileKind? = nil, source: String? = nil, sort: FileSort = .name) async -> [IndexedFile] {
        await index.files(kind: kind, source: source, parent: nil, sort: sort, limit: 1_000, offset: 0)
    }

    @Test func upsertAndQueryByKind() async throws {
        let index = try FileIndex.inMemory()
        let pass = await index.beginPass()
        try await index.upsert([
            Self.record("/u/Pictures/a.jpg", kind: .image), Self.record("/u/Docs/b.pdf"),
            Self.record("/u/Pictures/c.png", kind: .screenshot),
        ], generation: pass)
        #expect(await index.count() == 3)
        let images = await Self.all(index, kind: .image)
        #expect(images.map(\.name) == ["a.jpg"])
        let image = try #require(images.first)
        #expect(image.path == "/u/Pictures/a.jpg" && image.parent == "/u/Pictures" && image.fileExtension == "jpg")
        #expect(image.added == Date(timeIntervalSince1970: 1_000) && image.source == nil && !image.isCloudOnly)

        try await index.upsert([Self.record("/u/Pictures/a.jpg", kind: .image, bytes: 500)], generation: pass)
        #expect(await index.count() == 3)
        #expect(await Self.all(index, kind: .image).first?.bytes == 500)
        #expect(await Self.all(index, kind: .image).first?.id == image.id)
    }

    @Test func unchangedFilesKeepRecognizedContent() async throws {
        let index = try FileIndex.inMemory()
        let pass = await index.beginPass()
        let shot = Self.record("/u/Desktop/shot.png", kind: .screenshot, bytes: 50_000)
        try await index.upsert([shot, Self.record("/u/Docs/b.pdf")], generation: pass)
        let pending = await index.pendingRecognition(limit: 10)
        #expect(pending.map(\.name) == ["shot.png"])
        try await index.setContent(id: try #require(pending.first).id, text: "INVOICE 1042", labels: ["document"])
        #expect(await index.pendingRecognition(limit: 10).isEmpty)
        #expect(await index.recognitionCounts() == (done: 1, pending: 0))

        try await index.upsert([shot], generation: await index.beginPass())
        #expect(await index.pendingRecognition(limit: 10).isEmpty)

        try await index.upsert([Self.record("/u/Desktop/shot.png", kind: .screenshot, bytes: 50_000, modified: 2_000)], generation: pass)
        #expect(await index.pendingRecognition(limit: 10).map(\.name) == ["shot.png"])
        #expect(await index.recognitionCounts() == (done: 0, pending: 1))
    }

    @Test func pendingRecognitionSkipsCloudHugeAndFailedImages() async throws {
        let index = try FileIndex.inMemory()
        try await index.upsert([
            Self.record("/u/a.jpg", kind: .image, bytes: 50_000, added: 1), Self.record("/u/b.jpg", kind: .image, bytes: 50_000, added: 3),
            Self.record("/u/cloud.jpg", kind: .image, bytes: 50_000, cloud: true),
            Self.record("/u/huge.png", kind: .image, bytes: 300_000_000),
            Self.record("/u/broken.jpg", kind: .image, bytes: 50_000, added: 2), Self.record("/u/movie.mov", kind: .video),
        ], generation: await index.beginPass())
        let broken = try #require(await Self.all(index).first { $0.name == "broken.jpg" })
        try await index.markRecognitionFailed(id: broken.id)
        #expect(await index.pendingRecognition(limit: 10).map(\.name) == ["b.jpg", "a.jpg"])
    }

    /// Icons and sprites rarely hold text worth finding, and a project can have tens of thousands.
    @Test func tinyImagesAreNotRead() async throws {
        let index = try FileIndex.inMemory()
        try await index.upsert([
            Self.record("/u/icon.png", kind: .image, bytes: 4_000), Self.record("/u/photo.jpg", kind: .image, bytes: 400_000),
        ], generation: await index.beginPass())
        #expect(await index.pendingRecognition(limit: 10).map(\.name) == ["photo.jpg"])
        #expect(await index.recognitionCounts() == (done: 0, pending: 1))
    }

    @Test func kindAndSourceSummaries() async throws {
        let index = try FileIndex.inMemory()
        try await index.upsert([
            Self.record("/u/a.jpg", kind: .image, bytes: 10), Self.record("/u/b.jpg", kind: .image, bytes: 20),
            Self.record("/u/c.pdf", bytes: 5, source: "ChatGPT"), Self.record("/u/d.zip", kind: .archive, bytes: 7, source: "ChatGPT"),
            Self.record("/u/e.pdf", bytes: 1, source: "Gmail"),
        ], generation: await index.beginPass())
        let kinds = await index.kindSummaries()
        #expect(kinds.first { $0.kind == .image } == KindSummary(kind: .image, count: 2, bytes: 30))
        #expect(kinds.first { $0.kind == .document } == KindSummary(kind: .document, count: 2, bytes: 6))
        #expect(await index.sourceSummaries() == [
            SourceSummary(source: "ChatGPT", count: 2, bytes: 12), SourceSummary(source: "Gmail", count: 1, bytes: 1),
        ])
        #expect(await Self.all(index, source: "ChatGPT").map(\.name) == ["c.pdf", "d.zip"])
    }

    @Test func recentIsNewestAddedFirst() async throws {
        let index = try FileIndex.inMemory()
        try await index.upsert([
            Self.record("/u/old.pdf", added: 10), Self.record("/u/newest.pdf", added: 30), Self.record("/u/mid.pdf", added: 20),
        ], generation: await index.beginPass())
        #expect(await index.recent(limit: 2).map(\.name) == ["newest.pdf", "mid.pdf"])
        #expect(await Self.all(index, sort: .added).map(\.name) == ["newest.pdf", "mid.pdf", "old.pdf"])
        #expect(await Self.all(index, sort: .size).count == 3)
    }

    @Test func pagingReturnsDisjointPages() async throws {
        let index = try FileIndex.inMemory()
        try await index.upsert((0..<25).map { Self.record("/u/f\($0).txt", added: Double($0)) }, generation: await index.beginPass())
        var seen: Set<Int64> = []
        var sizes: [Int] = []
        for page in 0..<3 {
            let rows = await index.files(kind: nil, source: nil, parent: nil, sort: .added, limit: 10, offset: page * 10)
            sizes.append(rows.count)
            seen.formUnion(rows.map(\.id))
        }
        #expect(sizes == [10, 10, 5])
        #expect(seen.count == 25)
    }

    @Test func removesFilesNotSeenInTheLatestPass() async throws {
        let index = try FileIndex.inMemory()
        let first = await index.beginPass()
        try await index.upsert([Self.record("/u/Docs/a.pdf"), Self.record("/u/Docs/b.pdf"), Self.record("/elsewhere/c.pdf")],
                               generation: first)
        let second = await index.beginPass()
        try await index.upsert([Self.record("/u/Docs/a.pdf")], generation: second)
        #expect(try await index.removeUnseen(under: ["/u"], generation: second) == 1)
        #expect(Set(await Self.all(index).map(\.name)) == ["a.pdf", "c.pdf"])
        try await index.remove(paths: ["/elsewhere/c.pdf"])
        #expect(await Self.all(index).map(\.name) == ["a.pdf"])
    }

    @Test func eraseAllEmptiesEverything() async throws {
        let index = try FileIndex.inMemory()
        try await index.upsert([Self.record("/u/a.jpg", kind: .image, source: "X")], generation: await index.beginPass())
        try await index.eraseAll()
        #expect(await index.count() == 0)
        #expect(await index.kindSummaries().isEmpty)
        #expect(await index.sourceSummaries().isEmpty)
        try await index.upsert([Self.record("/u/b.jpg", kind: .image)], generation: await index.beginPass())
        #expect(await index.count() == 1)
    }

    /// Forget Everything must not leave erased names and text in the write-ahead log.
    @Test func eraseAllLeavesNothingBehindOnDisk() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let url = URL(fileURLWithPath: fx.path("Unearth/index.sqlite"))
        let index = try FileIndex(url: url)
        try await index.upsert((0..<300).map { Self.record("/u/secretplan\($0).png", kind: .image, bytes: 50_000) },
                               generation: await index.beginPass())
        for file in await index.pendingRecognition(limit: 50) {
            try await index.setContent(id: file.id, text: "TOPSECRETWORD", labels: ["dog"])
        }
        try await index.eraseAll()
        for suffix in ["", "-wal"] {
            let data = (try? Data(contentsOf: URL(fileURLWithPath: url.path + suffix))) ?? Data()
            #expect(data.range(of: Data("secretplan".utf8)) == nil, "found in index.sqlite\(suffix)")
            #expect(data.range(of: Data("TOPSECRETWORD".utf8)) == nil, "found in index.sqlite\(suffix)")
        }
    }

    /// A removed file's id must never be handed to a new file: selections and reads are kept by id.
    @Test func rowIDsAreNeverReused() async throws {
        let index = try FileIndex.inMemory()
        try await index.upsert([Self.record("/u/a.pdf"), Self.record("/u/b.pdf")], generation: await index.beginPass())
        let b = try #require(await Self.all(index).first { $0.name == "b.pdf" })
        try await index.remove(paths: ["/u/b.pdf"])
        try await index.upsert([Self.record("/u/c.pdf")], generation: await index.beginPass())
        let c = try #require(await Self.all(index).first { $0.name == "c.pdf" })
        #expect(c.id != b.id)
    }

    /// A late write from an older pass must not make a newer pass forget a file it just saw.
    @Test func seenNeverGoesBackwards() async throws {
        let index = try FileIndex.inMemory()
        let older = await index.beginPass()
        let newer = await index.beginPass()
        try await index.upsert([Self.record("/u/Docs/a.pdf"), Self.record("/u/Docs/sub/b.pdf")], generation: newer)
        try await index.upsert([Self.record("/u/Docs/a.pdf")], generation: older)
        try await index.markSeen(under: "/u/Docs/sub", generation: older)
        #expect(try await index.removeUnseen(under: ["/u"], generation: newer) == 0)
        #expect(await index.count() == 2)
    }

    /// Screens reload only when the index really changed, not on every write in a watched folder.
    @Test func upsertReportsOnlyRealChanges() async throws {
        let index = try FileIndex.inMemory()
        let a = Self.record("/u/a.pdf"), b = Self.record("/u/b.pdf")
        #expect(try await index.upsert([a, b], generation: await index.beginPass()) == 2)
        #expect(try await index.upsert([a, b], generation: await index.beginPass()) == 0)
        #expect(try await index.upsert([Self.record("/u/a.pdf", bytes: 200), b], generation: await index.beginPass()) == 1)
        #expect(try await index.upsert([Self.record("/u/b.pdf", source: "Gmail")], generation: await index.beginPass()) == 1)
    }

    /// Text read from an image is kept only if the image is still the one that was read.
    @Test func contentIsSavedOnlyForTheImageThatWasRead() async throws {
        let index = try FileIndex.inMemory()
        try await index.upsert([Self.record("/u/shot.png", kind: .screenshot, bytes: 50_000)], generation: await index.beginPass())
        let read = try #require(await index.pendingRecognition(limit: 1).first)
        try await index.upsert([Self.record("/u/shot.png", kind: .screenshot, bytes: 60_000, modified: 2_000)],
                               generation: await index.beginPass())
        try await index.setContent(for: read, text: "OLD TEXT", labels: [])
        #expect(await index.pendingRecognition(limit: 1).map(\.name) == ["shot.png"])
        let current = try #require(await index.pendingRecognition(limit: 1).first)
        try await index.setContent(for: current, text: "NEW TEXT", labels: [])
        #expect(await index.recognitionCounts() == (done: 1, pending: 0))
    }

    @Test func storesTheIndexOnDisk() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let url = URL(fileURLWithPath: fx.path("Unearth/index.sqlite"))
        do {
            let index = try FileIndex(url: url)
            try await index.upsert([Self.record("/u/a.pdf")], generation: await index.beginPass())
        }
        let reopened = try FileIndex(url: url)
        #expect(await reopened.count() == 1)
    }

    /// The tables as Stage 2 left them (schema version 2), to check an upgrade keeps what was read.
    static let version2Schema = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE files(
            id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL, parent TEXT NOT NULL,
            folder TEXT NOT NULL, words TEXT NOT NULL, kind TEXT NOT NULL, ext TEXT NOT NULL, bytes INTEGER NOT NULL,
            created REAL, modified REAL NOT NULL, added REAL NOT NULL, source TEXT, cloud INTEGER NOT NULL DEFAULT 0,
            content_state INTEGER NOT NULL DEFAULT 0, text TEXT NOT NULL DEFAULT '', labels TEXT NOT NULL DEFAULT '',
            seen INTEGER NOT NULL
        );
        CREATE INDEX files_kind_added ON files(kind, added);
        CREATE INDEX files_added ON files(added);
        CREATE INDEX files_parent ON files(parent);
        CREATE INDEX files_source ON files(source);
        CREATE VIRTUAL TABLE file_text USING fts5(
            words, folder, text, labels, content = 'files', content_rowid = 'id',
            tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3'
        );
        CREATE TRIGGER files_added_text AFTER INSERT ON files BEGIN
            INSERT INTO file_text(rowid, words, folder, text, labels) VALUES (new.id, new.words, new.folder, new.text, new.labels);
        END;
        CREATE TRIGGER files_removed_text AFTER DELETE ON files BEGIN
            INSERT INTO file_text(file_text, rowid, words, folder, text, labels)
            VALUES ('delete', old.id, old.words, old.folder, old.text, old.labels);
        END;
        CREATE TRIGGER files_changed_text AFTER UPDATE ON files
        WHEN old.words IS NOT new.words OR old.folder IS NOT new.folder OR old.text IS NOT new.text
             OR old.labels IS NOT new.labels BEGIN
            INSERT INTO file_text(file_text, rowid, words, folder, text, labels)
            VALUES ('delete', old.id, old.words, old.folder, old.text, old.labels);
            INSERT INTO file_text(rowid, words, folder, text, labels) VALUES (new.id, new.words, new.folder, new.text, new.labels);
        END;
        PRAGMA user_version = 2;
        """

    @Test func aVersion2IndexKeepsWhatItRead() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let path = fx.path("index.sqlite")
        do {
            let db = try SQLiteDatabase(path: path)
            try db.execute(Self.version2Schema)
            try db.execute("""
                INSERT INTO files(path, name, parent, folder, words, kind, ext, bytes, created, modified, added, source,
                                  cloud, content_state, text, labels, seen)
                VALUES ('/u/Desktop/receipt.png', 'receipt.png', '/u/Desktop', 'Desktop', 'receipt png', 'screenshot',
                        'png', 50000, NULL, 1000, 1000, NULL, 0, 1, 'TOTAL 42 EUR', 'document', 1);
                """)
        }
        let index = try FileIndex(url: URL(fileURLWithPath: path))
        let files = await Self.all(index)
        #expect(files.map(\.name) == ["receipt.png"])
        var query = SearchQuery()
        query.text = "eur"
        #expect(await index.search(query, limit: 10).first?.file.name == "receipt.png")
        #expect(await index.recognitionCounts() == (done: 1, pending: 0))
        let file = try #require(files.first)
        try await index.storeHashes(for: file, partial: "p", full: "f")
        let cached = await index.cachedHashes(id: file.id)
        #expect(cached.partial == "p" && cached.full == "f")
        // A file that changes forgets its hashes.
        try await index.upsert([Self.record("/u/Desktop/receipt.png", kind: .screenshot, bytes: 60_000)],
                               generation: await index.beginPass())
        let after = await index.cachedHashes(id: file.id)
        #expect(after.partial == nil && after.full == nil)
    }

    @Test func recognizedTextIsReadBack() async throws {
        let index = try FileIndex.inMemory()
        try await index.upsert([
            Self.record("/u/a.png", kind: .screenshot, bytes: 50_000), Self.record("/u/b.png", kind: .screenshot, bytes: 50_000),
            Self.record("/u/c.jpg", kind: .image, bytes: 50_000),
        ], generation: await index.beginPass())
        let files = await Self.all(index)
        for file in files {
            let text = file.name == "c.jpg" ? "" : "Text in \(file.name)"
            try await index.setContent(id: file.id, text: text, labels: ["tree"])
        }
        let texts = await index.recognizedText(ids: files.map(\.id))
        #expect(texts.count == 2)
        #expect(Set(texts.values) == ["Text in a.png", "Text in b.png"])
        #expect(await index.recognizedText(ids: []).isEmpty)
    }

    @Test func idsWithTextAreListed() async throws {
        let index = try FileIndex.inMemory()
        try await index.upsert([
            Self.record("/u/a.png", kind: .screenshot, bytes: 50_000), Self.record("/u/b.png", kind: .screenshot, bytes: 50_000),
        ], generation: await index.beginPass())
        let files = await Self.all(index)
        let withText = try #require(files.first { $0.name == "a.png" })
        try await index.setContent(id: withText.id, text: "Hello", labels: [])
        #expect(await index.idsWithText() == [withText.id])
    }

    /// An index from before shot scores (version 3) keeps its hashes and prints and gains a place for scores.
    @Test func aVersion3IndexGainsScores() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let path = fx.path("index.sqlite")
        do {
            let db = try SQLiteDatabase(path: path)
            try db.execute(Self.version2Schema)
            try db.execute("""
                ALTER TABLE files ADD COLUMN partial_hash TEXT;
                ALTER TABLE files ADD COLUMN full_hash TEXT;
                ALTER TABLE files ADD COLUMN print BLOB;
                PRAGMA user_version = 3;
                INSERT INTO files(path, name, parent, folder, words, kind, ext, bytes, created, modified, added, source,
                                  cloud, content_state, text, labels, seen, partial_hash, full_hash, print)
                VALUES ('/u/Pictures/beach.jpg', 'beach.jpg', '/u/Pictures', 'Pictures', 'beach jpg', 'image', 'jpg',
                        50000, NULL, 1000, 1000, NULL, 0, 1, '', 'sea', 1, 'p', 'f', x'01020304');
                """)
        }
        let index = try FileIndex(url: URL(fileURLWithPath: path))
        let file = try #require(await Self.all(index).first)
        #expect(await index.cachedHashes(id: file.id).full == "f")
        #expect(await index.prints(ids: [file.id])[file.id] == Data([1, 2, 3, 4]))
        try await index.storeScore(for: file, score: 0.5)
        #expect(await index.scores(ids: [file.id]) == [file.id: 0.5])
        // A file that changes forgets its score.
        try await index.upsert([Self.record("/u/Pictures/beach.jpg", kind: .image, bytes: 60_000)], generation: await index.beginPass())
        #expect(await index.scores(ids: [file.id]).isEmpty)
    }
}

