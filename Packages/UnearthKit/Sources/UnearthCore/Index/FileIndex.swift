import Foundation

/// A file as the Library shows it.
public struct IndexedFile: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let path: String
    public let name: String
    public let parent: String
    public let kind: FileKind
    public let fileExtension: String
    /// The file's size, as Finder shows it (also for files whose contents are only in iCloud).
    public let bytes: Int64
    public let created: Date?
    public let modified: Date
    /// When the file arrived in its folder: downloaded, copied or moved in.
    public let added: Date
    public let source: String?
    public let isCloudOnly: Bool

    /// For files shown outside the index, like a live folder listing.
    public init(
        id: Int64, path: String, name: String, parent: String, kind: FileKind, fileExtension: String, bytes: Int64,
        created: Date?, modified: Date, added: Date, source: String?, isCloudOnly: Bool
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.parent = parent
        self.kind = kind
        self.fileExtension = fileExtension
        self.bytes = bytes
        self.created = created
        self.modified = modified
        self.added = added
        self.source = source
        self.isCloudOnly = isCloudOnly
    }

    /// When the file was made, as best the disk can tell: the earlier of when it was created and when it last
    /// changed, since a copy or an unzipped file is created anew but keeps the date it last changed.
    public var made: Date { min(created ?? modified, modified) }
}

/// What the indexer found on disk for one file.
public struct IndexedFileRecord: Sendable {
    public var path: String
    public var name: String
    public var parent: String
    /// The parent folder from the indexed folder down ("Documents/Taxes"), for search.
    public var folder: String
    public var kind: FileKind
    public var fileExtension: String
    public var bytes: Int64
    public var created: Date?
    public var modified: Date
    public var added: Date
    public var source: String?
    public var isCloudOnly: Bool

    public init(
        path: String, name: String, parent: String, folder: String, kind: FileKind, fileExtension: String, bytes: Int64,
        created: Date?, modified: Date, added: Date, source: String?, isCloudOnly: Bool
    ) {
        self.path = path
        self.name = name
        self.parent = parent
        self.folder = folder
        self.kind = kind
        self.fileExtension = fileExtension
        self.bytes = bytes
        self.created = created
        self.modified = modified
        self.added = added
        self.source = source
        self.isCloudOnly = isCloudOnly
    }
}

public enum FileSort: String, Sendable, CaseIterable {
    /// When made (`IndexedFile.made`), newest first.
    case made
    case added, name, size, kind
}

public struct KindSummary: Sendable, Equatable {
    public let kind: FileKind
    public let count: Int
    public let bytes: Int64
}

public struct SourceSummary: Sendable, Equatable {
    public let source: String
    public let count: Int
    public let bytes: Int64
}

/// The Library's catalog of files, kept on this Mac: one row per file plus a full-text index over
/// names, folders, and the text and objects found in images.
public actor FileIndex {
    /// Whether text and objects have been read from a file.
    enum ContentState: Int64 {
        case pending = 0, done = 1, failed = 2, notApplicable = 3
    }

    /// Images bigger than this aren't read: they're slow and rarely screenshots or documents.
    static let recognitionLimit: Int64 = 200_000_000
    /// Nor smaller ones: icons and sprites rarely hold text worth finding, and a project can have thousands.
    static let recognitionMinimum: Int64 = 10_000
    static let recognizableKinds = "('image', 'screenshot')"

    let db: SQLiteDatabase
    private var generation: Int64
    private var statements: [String: SQLiteStatement] = [:]

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(path: url.path)
    }

    /// For tests: nothing touches the disk.
    public static func inMemory() throws -> FileIndex {
        try FileIndex(path: ":memory:")
    }

    /// Bumped when the tables change. Versions 2 and 3 are upgraded in place, keeping what was read from images;
    /// any other older index is rebuilt from the folders.
    static let schemaVersion: Int64 = 4

    private init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        var version = try db.prepare("PRAGMA user_version").rows { $0.int64(0) }.first ?? 0
        if version == 2 {
            try Self.upgradeFromVersion2(db)
            version = 3
        }
        if version == 3 {
            try Self.upgradeFromVersion3(db)
            version = 4
        }
        if version != 0, version != Self.schemaVersion { try Self.dropSchema(db) }
        try Self.createSchema(db)
        // Only for speed: a disk too full to build these mustn't cost the whole Library.
        for columns in ["kind", "parent", "source"] {
            try? db.execute("CREATE INDEX IF NOT EXISTS files_\(columns)_made ON files(\(columns), \(Self.made))")
        }
        generation = try db.prepare("SELECT coalesce(max(seen), 0) FROM files").rows { $0.int64(0) }.first ?? 0
    }

    private static func createSchema(_ db: SQLiteDatabase) throws {
        try db.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS files(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL,
                parent TEXT NOT NULL,
                folder TEXT NOT NULL,
                words TEXT NOT NULL,
                kind TEXT NOT NULL,
                ext TEXT NOT NULL,
                bytes INTEGER NOT NULL,
                created REAL,
                modified REAL NOT NULL,
                added REAL NOT NULL,
                source TEXT,
                cloud INTEGER NOT NULL DEFAULT 0,
                content_state INTEGER NOT NULL DEFAULT 0,
                text TEXT NOT NULL DEFAULT '',
                labels TEXT NOT NULL DEFAULT '',
                seen INTEGER NOT NULL,
                partial_hash TEXT,
                full_hash TEXT,
                print BLOB,
                score REAL
            );
            CREATE INDEX IF NOT EXISTS files_kind_added ON files(kind, added);
            CREATE INDEX IF NOT EXISTS files_bytes ON files(bytes);
            CREATE INDEX IF NOT EXISTS files_added ON files(added);
            CREATE INDEX IF NOT EXISTS files_parent ON files(parent);
            CREATE INDEX IF NOT EXISTS files_source ON files(source);
            CREATE VIRTUAL TABLE IF NOT EXISTS file_text USING fts5(
                words, folder, text, labels, content = 'files', content_rowid = 'id',
                tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3'
            );
            CREATE TRIGGER IF NOT EXISTS files_added_text AFTER INSERT ON files BEGIN
                INSERT INTO file_text(rowid, words, folder, text, labels)
                VALUES (new.id, new.words, new.folder, new.text, new.labels);
            END;
            CREATE TRIGGER IF NOT EXISTS files_removed_text AFTER DELETE ON files BEGIN
                INSERT INTO file_text(file_text, rowid, words, folder, text, labels)
                VALUES ('delete', old.id, old.words, old.folder, old.text, old.labels);
            END;
            CREATE TRIGGER IF NOT EXISTS files_changed_text AFTER UPDATE ON files
            WHEN old.words IS NOT new.words OR old.folder IS NOT new.folder OR old.text IS NOT new.text
                 OR old.labels IS NOT new.labels BEGIN
                INSERT INTO file_text(file_text, rowid, words, folder, text, labels)
                VALUES ('delete', old.id, old.words, old.folder, old.text, old.labels);
                INSERT INTO file_text(rowid, words, folder, text, labels)
                VALUES (new.id, new.words, new.folder, new.text, new.labels);
            END;
            PRAGMA user_version = \(schemaVersion);
            """)
    }

    /// Adds the duplicate hashes and feature prints in one transaction, so a crash can't leave half of it.
    private static func upgradeFromVersion2(_ db: SQLiteDatabase) throws {
        try db.execute("""
            BEGIN IMMEDIATE;
            ALTER TABLE files ADD COLUMN partial_hash TEXT;
            ALTER TABLE files ADD COLUMN full_hash TEXT;
            ALTER TABLE files ADD COLUMN print BLOB;
            PRAGMA user_version = 3;
            COMMIT;
            """)
    }

    /// Adds the photos' shot scores, so each photo is scored once rather than on every launch.
    private static func upgradeFromVersion3(_ db: SQLiteDatabase) throws {
        try db.execute("""
            BEGIN IMMEDIATE;
            ALTER TABLE files ADD COLUMN score REAL;
            PRAGMA user_version = 4;
            COMMIT;
            """)
    }

    private static func dropSchema(_ db: SQLiteDatabase) throws {
        try db.execute("""
            DROP TRIGGER IF EXISTS files_added_text; DROP TRIGGER IF EXISTS files_removed_text;
            DROP TRIGGER IF EXISTS files_changed_text; DROP TABLE IF EXISTS file_text; DROP TABLE IF EXISTS files;
            """)
    }

    func statement(_ sql: String) throws -> SQLiteStatement {
        if let cached = statements[sql] { return cached }
        let prepared = try db.prepare(sql)
        statements[sql] = prepared
        return prepared
    }

    // MARK: - Writing

    /// Starts a pass over the folders; files the pass doesn't see can then be removed with `removeUnseen`.
    public func beginPass() -> Int64 {
        generation += 1
        return generation
    }

    /// Adds or updates files, returning how many were new or changed. A file whose size and modification
    /// date haven't changed keeps what was read from it. `seen` only ever goes up, so a late write from an
    /// older pass can't make a newer pass forget a file.
    @discardableResult
    public func upsert(_ files: [IndexedFileRecord], generation: Int64) throws -> Int {
        let touch = try statement("""
            UPDATE files SET seen = max(seen, ?1)
            WHERE path = ?2 AND name = ?3 AND parent = ?4 AND folder = ?5 AND kind = ?6 AND ext = ?7 AND bytes = ?8
                  AND created IS ?9 AND modified = ?10 AND added = ?11 AND source IS ?12 AND cloud = ?13
            """)
        let upsert = try statement("""
            INSERT INTO files(path, name, parent, folder, words, kind, ext, bytes, created, modified, added, source, cloud,
                              content_state, seen)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
            ON CONFLICT(path) DO UPDATE SET
                content_state = CASE WHEN \(Self.unchanged) THEN files.content_state ELSE excluded.content_state END,
                text = CASE WHEN \(Self.unchanged) THEN files.text ELSE '' END,
                labels = CASE WHEN \(Self.unchanged) THEN files.labels ELSE '' END,
                partial_hash = CASE WHEN \(Self.unchanged) THEN files.partial_hash ELSE NULL END,
                full_hash = CASE WHEN \(Self.unchanged) THEN files.full_hash ELSE NULL END,
                print = CASE WHEN \(Self.unchanged) THEN files.print ELSE NULL END,
                score = CASE WHEN \(Self.unchanged) THEN files.score ELSE NULL END,
                name = excluded.name, parent = excluded.parent, folder = excluded.folder, words = excluded.words,
                kind = excluded.kind, ext = excluded.ext, bytes = excluded.bytes, created = excluded.created,
                modified = excluded.modified, added = excluded.added, source = excluded.source, cloud = excluded.cloud,
                seen = max(files.seen, excluded.seen)
            """)
        return try db.transaction {
            var changed = 0
            for file in files {
                try touch.run([
                    .integer(generation), .text(file.path), .text(file.name), .text(file.parent), .text(file.folder),
                    .text(file.kind.rawValue), .text(file.fileExtension), .integer(file.bytes), .optional(file.created),
                    .real(file.modified.timeIntervalSince1970), .real(file.added.timeIntervalSince1970),
                    .optional(file.source), .integer(file.isCloudOnly ? 1 : 0),
                ])
                if db.changes == 1 { continue }
                changed += 1
                let recognizable = file.kind == .image || file.kind == .screenshot
                try upsert.run([
                    .text(file.path), .text(file.name), .text(file.parent), .text(file.folder), .text(Self.words(file.name)),
                    .text(file.kind.rawValue), .text(file.fileExtension), .integer(file.bytes), .optional(file.created),
                    .real(file.modified.timeIntervalSince1970), .real(file.added.timeIntervalSince1970),
                    .optional(file.source), .integer(file.isCloudOnly ? 1 : 0),
                    .integer((recognizable ? ContentState.pending : ContentState.notApplicable).rawValue),
                    .integer(generation),
                ])
            }
            return changed
        }
    }

    private static let unchanged = "files.bytes = excluded.bytes AND files.modified = excluded.modified AND files.kind = excluded.kind"

    /// Removes files under `roots` that the pass with `generation` didn't see. Returns how many.
    @discardableResult
    public func removeUnseen(under roots: [String], generation: Int64) throws -> Int {
        let remove = try statement("DELETE FROM files WHERE seen < ?1 AND path > ?2 AND path < ?3")
        return try db.transaction {
            var removed = 0
            for root in roots {
                let (low, high) = Self.range(under: root)
                try remove.run([.integer(generation), .text(low), .text(high)])
                removed += db.changes
            }
            return removed
        }
    }

    public func remove(paths: [String]) throws {
        let remove = try statement("DELETE FROM files WHERE path = ?1")
        try db.transaction {
            for path in paths { try remove.run([.text(path)]) }
        }
    }

    func hasFiles(under folder: String) throws -> Bool {
        let (low, high) = Self.range(under: folder)
        return try !statement("SELECT 1 FROM files WHERE path > ?1 AND path < ?2 LIMIT 1").rows([.text(low), .text(high)]) { _ in () }.isEmpty
    }

    /// Counts files under `folder` as seen by a pass without listing them again.
    func markSeen(under folder: String, generation: Int64) throws {
        let (low, high) = Self.range(under: folder)
        try statement("UPDATE files SET seen = max(seen, ?1) WHERE path > ?2 AND path < ?3")
            .run([.integer(generation), .text(low), .text(high)])
    }

    public func setContent(id: Int64, text: String, labels: [String]) throws {
        try statement("UPDATE files SET text = ?1, labels = ?2, content_state = ?3 WHERE id = ?4")
            .run([.text(text), .text(labels.joined(separator: ", ")), .integer(ContentState.done.rawValue), .integer(id)])
    }

    /// Saves what was read from `file`, unless the image changed (or was read already) since it was handed out.
    /// `print` is a photo's feature print, for finding look-alikes; empty when Vision couldn't make one.
    public func setContent(for file: IndexedFile, text: String, labels: [String], print: Data? = nil) throws {
        try statement("""
            UPDATE files SET text = ?1, labels = ?2, content_state = ?3, print = coalesce(?8, print)
            WHERE id = ?4 AND bytes = ?5 AND modified = ?6 AND content_state = ?7
            """).run([
                .text(text), .text(labels.joined(separator: ", ")), .integer(ContentState.done.rawValue), .integer(file.id),
                .integer(file.bytes), .real(file.modified.timeIntervalSince1970), .integer(ContentState.pending.rawValue),
                print.map(SQLValue.blob) ?? .null,
            ])
    }

    /// Photos that were read before look-alikes existed, so they have no feature print yet. Newest first.
    public func needingPrints(limit: Int) -> [IndexedFile] {
        (try? statement("""
            SELECT \(Self.columns) FROM files
            WHERE kind = 'image' AND content_state = \(ContentState.done.rawValue) AND print IS NULL AND cloud = 0
                  AND ext IN (\(FileKinds.photoExtensions.sorted().map { "'\($0)'" }.joined(separator: ", ")))
            ORDER BY added DESC, files.id DESC LIMIT ?1
            """).rows([.integer(Int64(limit))], Self.file)) ?? []
    }

    /// Keeps a photo's feature print (empty: none could be made), unless the photo changed since it was handed out.
    public func setPrint(for file: IndexedFile, print: Data) throws {
        try statement("UPDATE files SET print = ?1 WHERE id = ?2 AND bytes = ?3 AND modified = ?4").run([
            .blob(print), .integer(file.id), .integer(file.bytes), .real(file.modified.timeIntervalSince1970),
        ])
    }

    /// Every file Vision found text in, so Copy Text is only offered where there's something to copy.
    public func idsWithText() -> Set<Int64> {
        Set((try? statement("SELECT id FROM files WHERE text != ''").rows([]) { $0.int64(0) }) ?? [])
    }

    /// The text Vision found in these images, for Copy Text. Images without any are left out.
    public func recognizedText(ids: [Int64]) -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        let list = "[" + ids.map(String.init).joined(separator: ",") + "]"
        let rows = try? statement("SELECT id, text FROM files WHERE id IN (SELECT value FROM json_each(?1)) AND text != ''")
            .rows([.text(list)]) { ($0.int64(0), $0.text(1) ?? "") }
        return Dictionary(rows ?? [], uniquingKeysWith: { first, _ in first })
    }

    /// Keeps a photo's shot score, unless the photo changed since it was handed out.
    public func storeScore(for file: IndexedFile, score: Float) throws {
        try statement("UPDATE files SET score = ?1 WHERE id = ?2 AND bytes = ?3 AND modified = ?4").run([
            .real(Double(score)), .integer(file.id), .integer(file.bytes), .real(file.modified.timeIntervalSince1970),
        ])
    }

    /// The shot scores these photos have.
    public func scores(ids: [Int64]) -> [Int64: Float] {
        guard !ids.isEmpty else { return [:] }
        let list = "[" + ids.map(String.init).joined(separator: ",") + "]"
        let rows = try? statement("SELECT id, score FROM files WHERE id IN (SELECT value FROM json_each(?1)) AND score IS NOT NULL")
            .rows([.text(list)]) { ($0.int64(0), Float($0.double(1))) }
        return Dictionary(rows ?? [], uniquingKeysWith: { first, _ in first })
    }

    /// Every photo on this Mac (not only in iCloud) that could have look-alikes, without the prints themselves.
    public func lookAlikePhotos() -> [IndexedFile] {
        (try? statement("SELECT \(Self.columns) FROM files WHERE kind = 'image' AND cloud = 0 ORDER BY files.id")
            .rows([], Self.file)) ?? []
    }

    /// The feature prints these photos have. Read a few at a time, since a whole library's prints are large.
    public func prints(ids: [Int64]) -> [Int64: Data] {
        guard !ids.isEmpty else { return [:] }
        let list = "[" + ids.map(String.init).joined(separator: ",") + "]"
        let rows = try? statement("""
            SELECT id, print FROM files
            WHERE id IN (SELECT value FROM json_each(?1)) AND print IS NOT NULL AND length(print) > 0
            """).rows([.text(list)]) { ($0.int64(0), $0.data(1) ?? Data()) }
        return Dictionary(rows ?? [], uniquingKeysWith: { first, _ in first })
    }

    public func markRecognitionFailed(id: Int64) throws {
        try statement("UPDATE files SET content_state = ?1 WHERE id = ?2").run([.integer(ContentState.failed.rawValue), .integer(id)])
    }

    /// Forgets everything: the tables, the space they used, and the write-ahead log that still held copies.
    public func eraseAll() throws {
        statements.removeAll()
        try Self.dropSchema(db)
        try db.execute("VACUUM")
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try Self.createSchema(db)
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        generation = 0
    }

    // MARK: - Reading

    static let columns = "files.id, path, name, parent, kind, ext, bytes, created, modified, added, source, cloud"
    /// `IndexedFile.made` in SQL. Spelled exactly as in the `files_kind_made` index, so queries can use it.
    static let made = "min(coalesce(created, modified), modified)"

    static func file(_ row: SQLiteStatement) -> IndexedFile {
        IndexedFile(
            id: row.int64(0), path: row.text(1) ?? "", name: row.text(2) ?? "", parent: row.text(3) ?? "",
            kind: FileKind(rawValue: row.text(4) ?? "") ?? .other, fileExtension: row.text(5) ?? "", bytes: row.int64(6),
            created: row.date(7), modified: row.date(8) ?? .distantPast, added: row.date(9) ?? .distantPast,
            source: row.text(10), isCloudOnly: row.int64(11) != 0)
    }

    static func order(_ sort: FileSort) -> String {
        switch sort {
        case .made: "\(made) DESC, files.id DESC"
        case .added: "added DESC, files.id DESC"
        case .name: "name COLLATE NOCASE, files.id"
        case .size: "bytes DESC, files.id"
        case .kind: "kind, name COLLATE NOCASE, files.id"
        }
    }

    public func files(kind: FileKind?, source: String?, parent: String?, sort: FileSort, limit: Int, offset: Int) -> [IndexedFile] {
        var conditions: [String] = []
        var values: [SQLValue] = []
        if let kind { conditions.append("kind = ?"); values.append(.text(kind.rawValue)) }
        if let source { conditions.append("source = ?"); values.append(.text(source)) }
        if let parent { conditions.append("parent = ?"); values.append(.text(parent)) }
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = "SELECT \(Self.columns) FROM files \(filter) ORDER BY \(Self.order(sort)) LIMIT ? OFFSET ?"
        return (try? statement(sql).rows(values + [.integer(Int64(limit)), .integer(Int64(offset))], Self.file)) ?? []
    }

    public func recent(limit: Int) -> [IndexedFile] {
        files(kind: nil, source: nil, parent: nil, sort: .added, limit: limit, offset: 0)
    }

    public func count() -> Int {
        Int((try? statement("SELECT count(*) FROM files").rows { $0.int64(0) }.first) ?? 0)
    }

    public func kindSummaries() -> [KindSummary] {
        (try? statement("SELECT kind, count(*), coalesce(sum(bytes), 0) FROM files GROUP BY kind").rows { row in
            KindSummary(kind: FileKind(rawValue: row.text(0) ?? "") ?? .other, count: Int(row.int64(1)), bytes: row.int64(2))
        }) ?? []
    }

    /// Most files first.
    public func sourceSummaries() -> [SourceSummary] {
        (try? statement("""
            SELECT source, count(*), coalesce(sum(bytes), 0) FROM files WHERE source IS NOT NULL
            GROUP BY source ORDER BY count(*) DESC, source
            """).rows { SourceSummary(source: $0.text(0) ?? "", count: Int($0.int64(1)), bytes: $0.int64(2)) }) ?? []
    }

    /// Images and screenshots still to be read, newest first. iCloud-only, tiny and very large ones are left out.
    public func pendingRecognition(limit: Int) -> [IndexedFile] {
        (try? statement("""
            SELECT \(Self.columns) FROM files
            WHERE kind IN \(Self.recognizableKinds) AND content_state = \(ContentState.pending.rawValue) AND cloud = 0
                  AND bytes BETWEEN \(Self.recognitionMinimum) AND \(Self.recognitionLimit)
            ORDER BY added DESC, files.id DESC LIMIT ?1
            """).rows([.integer(Int64(limit))], Self.file)) ?? []
    }

    public func recognitionCounts() -> (done: Int, pending: Int) {
        let counts = try? statement("""
            SELECT coalesce(sum(content_state = \(ContentState.done.rawValue)), 0),
                   coalesce(sum(content_state = \(ContentState.pending.rawValue) AND cloud = 0
                                AND bytes BETWEEN \(Self.recognitionMinimum) AND \(Self.recognitionLimit)), 0)
            FROM files WHERE kind IN \(Self.recognizableKinds)
            """).rows { (done: Int($0.int64(0)), pending: Int($0.int64(1))) }.first
        return counts ?? (done: 0, pending: 0)
    }

    // MARK: - Helpers

    /// Path bounds for everything inside `folder`: "/" sorts just before "0".
    static func range(under folder: String) -> (String, String) {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return (prefix, String(prefix.dropLast()) + "0")
    }

    /// The name plus its camel-case and letter/digit parts, so "invoice" finds "MyInvoice2025.pdf".
    static func words(_ name: String) -> String {
        var split = ""
        var previous: Character?
        for character in name {
            if let previous,
               (previous.isLowercase && character.isUppercase) || (previous.isLetter && character.isNumber)
                || (previous.isNumber && character.isLetter) {
                split.append(" ")
            }
            split.append(character)
            previous = character
        }
        return split == name ? name : name + " " + split
    }
}
