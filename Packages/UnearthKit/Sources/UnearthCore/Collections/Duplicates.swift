import CryptoKit
import Darwin
import Foundation

/// Reads a file to tell whether it's an exact copy of another.
public protocol FileHashing: Sendable {
    /// The first and last 64 KB plus the size: cheap, and enough to tell most same-size files apart.
    func partialHash(of path: String) throws -> String
    /// SHA-256 of the whole file.
    func fullHash(of path: String) throws -> String
}

public enum HashingError: Error {
    case unreadable, notAFile, onlyInICloud
}

public struct SHA256Hasher: FileHashing {
    static let edge = 64 * 1_024
    static let chunk = 1_024 * 1_024

    public init() {}

    public func partialHash(of path: String) throws -> String {
        try withOpenFile(path) { fd, size in
            var hasher = SHA256()
            withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
            try Self.hash(fd, from: 0, count: min(size, Int64(Self.edge)), into: &hasher)
            if size > Int64(Self.edge) {
                let tail = max(Int64(Self.edge), size - Int64(Self.edge))
                try Self.hash(fd, from: tail, count: size - tail, into: &hasher)
            }
            return Self.hex(hasher.finalize())
        }
    }

    public func fullHash(of path: String) throws -> String {
        try withOpenFile(path) { fd, size in
            var hasher = SHA256()
            try Self.hash(fd, from: 0, count: size, into: &hasher)
            return Self.hex(hasher.finalize())
        }
    }

    /// Opens a regular file whose contents are on this Mac. A file that's only in iCloud is never read,
    /// since reading it would download it.
    private func withOpenFile<T>(_ path: String, _ body: (Int32, Int64) throws -> T) throws -> T {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw HashingError.unreadable }
        guard info.st_mode & S_IFMT == S_IFREG else { throw HashingError.notAFile }
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else { throw HashingError.onlyInICloud }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HashingError.unreadable }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0 else { throw HashingError.onlyInICloud }
        // Hashing reads each file once; keeping it in the cache would only push out what the Mac is using.
        _ = fcntl(fd, F_NOCACHE, 1)
        return try body(fd, Int64(info.st_size))
    }

    private static func hash(_ fd: Int32, from offset: Int64, count: Int64, into hasher: inout SHA256) throws {
        var buffer = [UInt8](repeating: 0, count: min(chunk, max(Int(count), 1)))
        var position = offset
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            let wanted = Int(min(Int64(buffer.count), remaining))
            let read = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, wanted, off_t(position)) }
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { throw HashingError.unreadable }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<read])) }
            position += Int64(read)
            remaining -= Int64(read)
        }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Whether two paths share their storage, so moving one to the Trash frees nothing.
public enum SharedStorage {
    /// Hard links to the same file, or APFS clones that haven't changed since they were made.
    public static func check(_ a: String, _ b: String) -> Bool {
        var first = stat()
        var second = stat()
        guard lstat(a, &first) == 0, lstat(b, &second) == 0, first.st_dev == second.st_dev else { return false }
        if first.st_ino == second.st_ino { return true }
        let clone = cloneID(a)
        return clone != 0 && clone == cloneID(b)
    }

    /// The clone id APFS keeps for a file (the same attribute the scanner reads in bulk), or 0.
    static func cloneID(_ path: String) -> UInt64 {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        // Read as an extended common attribute because of FSOPT_ATTR_CMN_EXTENDED.
        request.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID)
        var buffer = [UInt8](repeating: 0, count: 16)
        let result = buffer.withUnsafeMutableBytes {
            getattrlist(path, &request, $0.baseAddress, $0.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard result == 0 else { return 0 }
        // The buffer starts with its length (4 bytes), then the clone id.
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
    }
}

/// Exact copies of one file. One copy is always kept.
public struct DuplicateGroup: Sendable, Identifiable, Equatable {
    /// The copies' SHA-256.
    public let id: String
    /// Every copy, the one Unearth suggests keeping first.
    public let files: [IndexedFile]
    /// The copy that stays. The review page can change it.
    public var keep: IndexedFile.ID
    /// Which copies share storage with each other (clones, hard links), by family number.
    private let family: [IndexedFile.ID: Int]

    /// Keeps a copy in an organized folder over one in Downloads, then the oldest, then the first by path.
    init(id: String, copies: [IndexedFile], downloads: String, sharesStorage: (String, String) -> Bool) {
        self.id = id
        files = copies.sorted { a, b in
            let aDownloaded = Paths.isSameOrInside(a.path, downloads)
            let bDownloaded = Paths.isSameOrInside(b.path, downloads)
            if aDownloaded != bDownloaded { return bDownloaded }
            let aDate = a.created ?? a.added
            let bDate = b.created ?? b.added
            if aDate != bDate { return aDate < bDate }
            return a.path < b.path
        }
        keep = files[0].id
        var families: [IndexedFile.ID: Int] = [:]
        var representatives: [IndexedFile] = []
        for file in files {
            if let shared = representatives.firstIndex(where: { sharesStorage($0.path, file.path) }) {
                families[file.id] = shared
            } else {
                families[file.id] = representatives.count
                representatives.append(file)
            }
        }
        family = families
    }

    private init(id: String, files: [IndexedFile], keep: IndexedFile.ID, family: [IndexedFile.ID: Int]) {
        self.id = id
        self.files = files
        self.keep = keep
        self.family = family
    }

    /// This group without the copies `isGone` picks out, or nil when that leaves nothing to choose between. If the
    /// kept copy is one of them, the first copy left is kept instead.
    public func without(_ isGone: (IndexedFile) -> Bool) -> DuplicateGroup? {
        let left = files.filter { !isGone($0) }
        guard left.count > 1 else { return nil }
        return DuplicateGroup(id: id, files: left, keep: left.contains { $0.id == keep } ? keep : left[0].id, family: family)
    }

    /// Copies that share storage with the kept one: moving them to the Trash frees nothing.
    public var clones: Set<IndexedFile.ID> {
        Set(files.lazy.map(\.id).filter { $0 != keep && family[$0] == family[keep] })
    }

    /// The space the extra copies take: one copy's size for each separate copy besides the kept one.
    public var extraBytes: Int64 {
        let kept = family[keep]
        let others = Set(files.compactMap { family[$0.id] }.filter { $0 != kept })
        return Int64(others.count) * (files.first?.bytes ?? 0)
    }

    /// Every extra copy that frees space. Never the kept copy, so never every copy.
    public func defaultSelection() -> Set<IndexedFile.ID> {
        Set(files.lazy.map(\.id).filter { $0 != keep }).subtracting(clones)
    }

    /// Fresh groups after a look, with the user's choices carried over by group: a group already on the page keeps
    /// the copy they chose to keep and their ticks; copies new to a group, and new groups, start with their extras
    /// picked. Groups that are gone take their ticks with them.
    public static func merge(_ fresh: [DuplicateGroup], keeping previous: [DuplicateGroup], selection: Set<IndexedFile.ID>)
        -> (groups: [DuplicateGroup], selection: Set<IndexedFile.ID>) {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var picked: Set<IndexedFile.ID> = []
        let groups = fresh.map { group -> DuplicateGroup in
            var group = group
            guard let earlier = before[group.id] else {
                picked.formUnion(group.defaultSelection())
                return group
            }
            let ids = Set(group.files.map(\.id))
            if ids.contains(earlier.keep) { group.keep = earlier.keep }
            let seen = Set(earlier.files.map(\.id))
            let ticked = selection.intersection(seen).intersection(ids)
            let newcomers = group.defaultSelection().subtracting(seen)
            picked.formUnion(ticked.union(newcomers).subtracting([group.keep]))
            return group
        }
        return (groups, picked)
    }

    /// What may go to the Trash from `selected`: never the kept copy, and nothing at all when the kept copy
    /// is gone, since the extras might then be the last copies.
    public func trashable(_ selected: Set<IndexedFile.ID>, exists: (String) -> Bool) -> [IndexedFile] {
        guard let kept = files.first(where: { $0.id == keep }), exists(kept.path) else { return [] }
        return files.filter { selected.contains($0.id) && $0.id != keep }
    }
}

/// Finds exact copies among the Library's files: same size, then same partial hash, then same SHA-256.
public actor DuplicateFinder {
    private let index: FileIndex
    private let downloads: String
    private let hasher: any FileHashing
    private let sharesStorage: @Sendable (String, String) -> Bool
    private let isInCodeProject: @Sendable (String) -> Bool
    private let power: any PowerStateProviding

    /// `downloads` is the real path of ~/Downloads. `isInCodeProject` leaves out files in code projects,
    /// where a project's own asset and its build copy look like duplicates.
    public init(
        index: FileIndex, downloads: String, hasher: any FileHashing = SHA256Hasher(),
        sharesStorage: @escaping @Sendable (String, String) -> Bool = SharedStorage.check,
        isInCodeProject: @escaping @Sendable (String) -> Bool, power: any PowerStateProviding = SystemPowerState()
    ) {
        self.index = index
        self.downloads = downloads
        self.hasher = hasher
        self.sharesStorage = sharesStorage
        self.isInCodeProject = isInCodeProject
        self.power = power
    }

    /// Groups of copies of files of at least `minBytes`, the most space first. Hashes are kept in the index,
    /// so later runs only read files that changed. While the power rules say wait, nothing new is read.
    public func groups(minBytes: Int64) async -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []
        for sameSize in await index.duplicateCandidates(minBytes: minBytes) {
            if Task.isCancelled { break }
            let candidates = sameSize.filter { !FileKinds.isPackage(name: $0.name) && !isInCodeProject($0.path) }
            guard candidates.count > 1 else { continue }
            let paused = power.shouldPause
            for (_, sameStart) in await bucket(candidates, full: false, paused: paused) {
                for (digest, copies) in await bucket(sameStart, full: true, paused: paused) {
                    groups.append(DuplicateGroup(id: digest, copies: copies, downloads: downloads, sharesStorage: sharesStorage))
                }
            }
        }
        return groups.sorted { $0.extraBytes != $1.extraBytes ? $0.extraBytes > $1.extraBytes : $0.id < $1.id }
    }

    /// Files sorted by hash, keeping only hashes two or more files share. A full hash is only ever read
    /// for files that already share a size and a partial hash.
    private func bucket(_ files: [IndexedFile], full: Bool, paused: Bool) async -> [(String, [IndexedFile])] {
        var buckets: [String: [IndexedFile]] = [:]
        for file in files {
            guard let digest = await hash(file, full: full, paused: paused) else { continue }
            buckets[digest, default: []].append(file)
        }
        return buckets.keys.sorted().compactMap { key in buckets[key].flatMap { $0.count > 1 ? (key, $0) : nil } }
    }

    /// The cached hash, or a fresh one unless the power rules say wait.
    private func hash(_ file: IndexedFile, full: Bool, paused: Bool) async -> String? {
        let cached = await index.cachedHashes(id: file.id)
        if let digest = full ? cached.full : cached.partial { return digest }
        guard !paused, !Task.isCancelled else { return nil }
        guard let digest = try? (full ? hasher.fullHash(of: file.path) : hasher.partialHash(of: file.path)) else {
            return nil
        }
        try? await index.storeHashes(for: file, partial: full ? nil : digest, full: full ? digest : nil)
        return digest
    }
}

extension FileIndex {
    /// Files of at least `minBytes` that share their size with another file, by size, largest first.
    /// Files whose contents are only in iCloud are left out.
    func duplicateCandidates(minBytes: Int64) -> [[IndexedFile]] {
        let rows = (try? statement("""
            SELECT \(Self.columns) FROM files
            WHERE cloud = 0 AND bytes >= ?1 AND bytes IN (
                SELECT bytes FROM files WHERE cloud = 0 AND bytes >= ?1 GROUP BY bytes HAVING count(*) > 1)
            ORDER BY bytes DESC, files.id
            """).rows([.integer(minBytes)], Self.file)) ?? []
        var groups: [[IndexedFile]] = []
        for file in rows {
            if let last = groups.last?.last, last.bytes == file.bytes {
                groups[groups.count - 1].append(file)
            } else {
                groups.append([file])
            }
        }
        return groups
    }

    func cachedHashes(id: Int64) -> (partial: String?, full: String?) {
        let rows = try? statement("SELECT partial_hash, full_hash FROM files WHERE id = ?1")
            .rows([.integer(id)]) { (partial: $0.text(0), full: $0.text(1)) }
        return rows?.first ?? (partial: nil, full: nil)
    }

    /// Keeps hashes read from `file`, unless the file changed since it was handed out.
    func storeHashes(for file: IndexedFile, partial: String?, full: String?) throws {
        try statement("""
            UPDATE files SET partial_hash = coalesce(?1, partial_hash), full_hash = coalesce(?2, full_hash)
            WHERE id = ?3 AND bytes = ?4 AND modified = ?5
            """).run([
                .optional(partial), .optional(full), .integer(file.id),
                .integer(file.bytes), .real(file.modified.timeIntervalSince1970),
            ])
    }
}
