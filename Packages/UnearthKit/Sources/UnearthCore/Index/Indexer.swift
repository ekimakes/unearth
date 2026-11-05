import Foundation

public struct IndexStats: Sendable {
    public let files: Int
    /// Files that were new or changed since the last pass.
    public let changed: Int
    public let removed: Int
    public let elapsed: Duration
}

/// Walks the Library's folders into the index. Never enters hidden folders, caches, dependency folders
/// (node_modules, Pods…), Photos libraries, other volumes or excluded folders. Apps and other packages are
/// listed as one item each; an Applications folder lists only its apps.
public actor Indexer {
    private static let batchSize = 1_000

    private let index: FileIndex
    private let reader: any DirectoryReading
    private let excludedPaths: [String]
    private let packageSize: @Sendable (String) -> Int64?
    /// The folders of the last full pass; refreshes stay inside them.
    private var roots: [String] = []

    /// `packageSize` can answer a package's size from an earlier disk scan; otherwise the package is walked.
    public init(
        index: FileIndex, reader: any DirectoryReading = BulkDirectoryReader(), excludedPaths: [String] = [],
        packageSize: @escaping @Sendable (String) -> Int64? = { _ in nil }
    ) {
        self.index = index
        self.reader = reader
        self.excludedPaths = excludedPaths
        self.packageSize = packageSize
    }

    public func index(roots: [String], progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> IndexStats {
        let start = ContinuousClock.now
        self.roots = roots
        let generation = await index.beginPass()
        var pending: [IndexedFileRecord] = []
        var total = 0
        var changed = 0
        for root in roots {
            var folders = [root]
            while let folder = folders.popLast() {
                try Task.checkCancellation()
                let listing: (files: [IndexedFileRecord], folders: [String])
                do {
                    listing = try list(folder)
                } catch .notFound {
                    continue
                } catch {
                    // Unreadable right now isn't gone: keep what's known under it.
                    try await index.markSeen(under: folder, generation: generation)
                    continue
                }
                pending += listing.files
                folders += listing.folders
                if pending.count >= Self.batchSize {
                    changed += try await index.upsert(pending, generation: generation)
                    total += pending.count
                    pending.removeAll(keepingCapacity: true)
                    progress(total)
                }
            }
        }
        changed += try await index.upsert(pending, generation: generation)
        total += pending.count
        progress(total)
        let removed = try await index.removeUnseen(under: roots, generation: generation)
        return IndexStats(files: total, changed: changed, removed: removed, elapsed: ContinuousClock.now - start)
    }

    /// Lists just these folders again after they changed. Folders that are new to the index are walked
    /// in full (they may have been moved in whole); files and folders that are gone are dropped.
    /// Returns how many files were added, changed or removed.
    @discardableResult
    public func refresh(directories: [String]) async throws -> Int {
        let generation = await index.beginPass()
        var changed = 0
        for directory in Set(directories) where isIndexed(directory) {
            try Task.checkCancellation()
            let listing: (files: [IndexedFileRecord], folders: [String])
            do {
                listing = try list(directory)
            } catch .notFound {
                changed += try await index.removeUnseen(under: [directory], generation: generation)
                continue
            } catch {
                continue   // unreadable right now isn't gone
            }
            var files = listing.files
            for folder in listing.folders {
                if try await index.hasFiles(under: folder) {
                    try await index.markSeen(under: folder, generation: generation)
                } else {
                    files += walk(folder)
                }
            }
            changed += try await index.upsert(files, generation: generation)
            changed += try await index.removeUnseen(under: [directory], generation: generation)
        }
        return changed
    }

    // MARK: - Walking

    /// The folder's files and the subfolders worth entering.
    private func list(_ folder: String) throws(DirectoryReadError) -> (files: [IndexedFileRecord], folders: [String]) {
        let entries = try reader.entries(ofDirectoryAt: folder)
        // Apps keep their resources next to them in Applications; only the apps belong in the Library.
        let appsOnly = root(of: folder).map { ($0 as NSString).lastPathComponent == "Applications" } ?? false
        var files: [IndexedFileRecord] = []
        var folders: [String] = []
        for entry in entries where !entry.name.hasPrefix(".") {
            let path = Paths.join(folder, entry.name)
            switch entry.kind {
            case .file:
                if !appsOnly { files.append(record(entry, at: path, bytes: entry.logicalSize)) }
            case .directory:
                guard !entry.isMountPoint, !Self.isSkippedFolder(entry.name), !isExcluded(path) else { continue }
                if FileKinds.isPackage(name: entry.name) {
                    guard !appsOnly || FileClassifier.kind(forName: entry.name, isScreenshot: false) == .app else { continue }
                    files.append(record(entry, at: path, bytes: packageSize(path) ?? size(of: path)))
                } else {
                    folders.append(path)
                }
            case .symlink, .other:
                continue
            }
        }
        return (files, folders)
    }

    private func walk(_ folder: String) -> [IndexedFileRecord] {
        var files: [IndexedFileRecord] = []
        var folders = [folder]
        while let next = folders.popLast() {
            guard let listing = try? list(next) else { continue }
            files += listing.files
            folders += listing.folders
        }
        return files
    }

    /// A package's size: the sum of its files' sizes.
    private func size(of package: String) -> Int64 {
        var total: Int64 = 0
        var folders = [package]
        while let folder = folders.popLast() {
            for entry in (try? reader.entries(ofDirectoryAt: folder)) ?? [] {
                if entry.kind == .directory {
                    if !entry.isMountPoint { folders.append(Paths.join(folder, entry.name)) }
                } else {
                    total += entry.logicalSize
                }
            }
        }
        return total
    }

    private func record(_ entry: DirectoryEntry, at path: String, bytes: Int64) -> IndexedFileRecord {
        let parent = (path as NSString).deletingLastPathComponent
        var kind = FileClassifier.kind(forName: entry.name, isScreenshot: false)
        if kind == .image, DownloadSource.isScreenCapture(atPath: path) { kind = .screenshot }
        let added = entry.addedDate ?? entry.creationDate ?? entry.modificationDate
        return IndexedFileRecord(
            path: path, name: entry.name, parent: parent, folder: folder(of: parent), kind: kind,
            fileExtension: FileClassifier.fileExtension(entry.name), bytes: bytes, created: entry.creationDate,
            modified: entry.modificationDate, added: added,
            source: DownloadSource.name(for: DownloadSource.whereFroms(atPath: path)), isCloudOnly: entry.isDataless)
    }

    // MARK: - Where the index goes

    /// Caches and downloaded dependencies hold no files of the user's own, often by the ten thousand.
    private static let skippedFolders: Set<String> = [
        "node_modules", "pods", "deriveddata", "__pycache__", "site-packages", "venv",
        "cache", "caches", "cacheddata", "code cache", "gpucache",
    ]

    private static func isSkippedFolder(_ name: String) -> Bool {
        let lower = name.lowercased()
        return skippedFolders.contains(lower) || lower.hasSuffix(".photoslibrary")
    }

    /// Inside an excluded folder (~/Library), unless the user chose a folder in there (iCloud Drive).
    private func isExcluded(_ path: String) -> Bool {
        excludedPaths.contains { excluded in
            Paths.isSameOrInside(path, excluded)
                && !roots.contains { Paths.isSameOrInside($0, excluded) && Paths.isSameOrInside(path, $0) }
        }
    }

    private func root(of path: String) -> String? {
        roots.filter { Paths.isSameOrInside(path, $0) }.max { $0.count < $1.count }
    }

    /// Inside a root and not in any place a full pass skips.
    private func isIndexed(_ directory: String) -> Bool {
        guard let root = root(of: directory), !isExcluded(directory) else { return false }
        let below = directory.dropFirst(root.count).split(separator: "/")
        return !below.contains { $0.hasPrefix(".") || Self.isSkippedFolder(String($0)) || FileKinds.isPackage(name: String($0)) }
    }

    /// "Documents/Taxes" for a folder inside the indexed Documents folder.
    private func folder(of parent: String) -> String {
        guard let root = root(of: parent) else { return (parent as NSString).lastPathComponent }
        return (root as NSString).lastPathComponent + parent.dropFirst(root.count)
    }
}
