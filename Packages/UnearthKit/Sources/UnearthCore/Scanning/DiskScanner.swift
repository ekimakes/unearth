import Darwin
import Foundation
import Synchronization

public struct ScanOptions: Sendable {
    /// Real path to scan (e.g. "/System/Volumes/Data").
    public var rootPath: String
    /// What `rootPath` is shown as (e.g. "/"), so paths read "/Users/…".
    public var displayRoot: String
    /// Absolute real paths that are never entered.
    public var excludedPaths: Set<String>
    public var bigFileFloor: Int64 = 50_000_000
    /// Past eight a full disk scans no faster: the extra workers only load the Mac.
    public var workerCount: Int = min(8, ProcessInfo.processInfo.activeProcessorCount)
    /// A scan someone is waiting for takes the Mac's attention; one behind the scenes gives way to everything else.
    public var priority: DispatchQoS.QoSClass = .userInitiated

    public init(rootPath: String, displayRoot: String? = nil, excludedPaths: Set<String> = []) {
        self.rootPath = rootPath
        self.displayRoot = displayRoot ?? rootPath
        self.excludedPaths = excludedPaths
    }
}

public struct ScanProgress: Sendable, Equatable {
    public let files: Int
    public let directories: Int
    public let bytes: Int64
    public let currentPath: String

    public init(files: Int, directories: Int, bytes: Int64, currentPath: String) {
        self.files = files
        self.directories = directories
        self.bytes = bytes
        self.currentPath = currentPath
    }
}

/// Walks a volume in parallel and builds a `ScanTree`.
///
/// Counted bytes per file: 0 for iCloud placeholders; 0 for a hard link already seen; the private
/// (unshared) size for an APFS clone whose clone family was already seen; otherwise the allocated size.
public struct DiskScanner: Sendable {
    private let reader: any DirectoryReading

    public init(reader: any DirectoryReading = BulkDirectoryReader()) {
        self.reader = reader
    }

    public func scan(
        _ options: ScanOptions, progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> ScanTree {
        try Task.checkCancellation()
        let start = ContinuousClock.now
        let rootDevice = try reader.deviceID(ofDirectoryAt: options.rootPath)
        let state = ScanState(options: options, reader: reader, rootDevice: rootDevice)

        let ticker = Task.detached {
            while !state.finished.load(ordering: .acquiring) {
                progress(state.progressSnapshot())
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { ticker.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: options.priority).async {
                    // getattrlistbulk blocks, so the workers live on GCD threads, not the cooperative pool.
                    DispatchQueue.concurrentPerform(iterations: max(1, options.workerCount)) { _ in
                        state.runWorker()
                    }
                    state.finished.store(true, ordering: .releasing)
                    if state.cancelled.load(ordering: .acquiring) {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            state.cancelled.store(true, ordering: .releasing)
        }

        progress(state.progressSnapshot())
        return state.buildTree(elapsed: ContinuousClock.now - start)
    }
}

// MARK: - Shared scan state

private final class ScanState: Sendable {
    struct Draft {
        var name: String
        var parent: Int32
        var children: [Int32] = []
        var ownBytes: Int64 = 0
        var ownMediaBytes: Int64 = 0
        var ownFileCount: Int32 = 0
        var markers: ProjectMarkers = []
        var isInaccessible = false
        var vanished = false
        var newestOwn: Date?
    }

    struct WorkItem {
        let index: Int32
        let path: String
    }

    let options: ScanOptions
    let reader: any DirectoryReading
    let rootDevice: Int32

    let finished = Atomic<Bool>(false)
    let cancelled = Atomic<Bool>(false)
    private let drafts: Mutex<[Draft]>
    private let queue: Mutex<[WorkItem]>
    private let pending = Atomic<Int>(1)
    private let seenLinks = Mutex<Set<UInt64>>([])
    private let seenClones = Mutex<Set<UInt64>>([])
    private let bigFiles = Mutex<[BigFile]>([])
    private let currentPath = Mutex<String>("")
    private let fileCount = Atomic<Int>(0)
    private let directoryCount = Atomic<Int>(0)
    private let byteCount = Atomic<Int>(0)
    private let inaccessibleCount = Atomic<Int>(0)
    private let mountPointCount = Atomic<Int>(0)
    private let cloudOnlyCount = Atomic<Int>(0)

    init(options: ScanOptions, reader: any DirectoryReading, rootDevice: Int32) {
        self.options = options
        self.reader = reader
        self.rootDevice = rootDevice
        drafts = Mutex([Draft(name: options.displayRoot, parent: -1)])
        queue = Mutex([WorkItem(index: 0, path: options.rootPath)])
    }

    func runWorker() {
        while !cancelled.load(ordering: .relaxed) {
            guard let item = queue.withLock({ $0.popLast() }) else {
                if pending.load(ordering: .acquiring) == 0 { return }
                usleep(200)
                continue
            }
            process(item)
            pending.subtract(1, ordering: .releasing)
        }
    }

    func progressSnapshot() -> ScanProgress {
        ScanProgress(
            files: fileCount.load(ordering: .relaxed), directories: directoryCount.load(ordering: .relaxed),
            bytes: Int64(byteCount.load(ordering: .relaxed)), currentPath: displayPath(currentPath.withLock { $0 }))
    }

    private func process(_ item: WorkItem) {
        currentPath.withLock { $0 = item.path }
        let entries: [DirectoryEntry]
        do {
            entries = try reader.entries(ofDirectoryAt: item.path)
        } catch .notFound {
            drafts.withLock { $0[Int(item.index)].vanished = true }
            return
        } catch {
            drafts.withLock { $0[Int(item.index)].isInaccessible = true }
            inaccessibleCount.add(1, ordering: .relaxed)
            return
        }
        directoryCount.add(1, ordering: .relaxed)

        var ownBytes: Int64 = 0
        var mediaBytes: Int64 = 0
        var files: Int32 = 0
        var markers: ProjectMarkers = []
        var newest: Date?
        var childDirectories: [(name: String, path: String)] = []
        var big: [BigFile] = []

        for entry in entries {
            markers.formUnion(FileKinds.marker(forEntryNamed: entry.name))
            if entry.kind == .directory {
                // Other volumes (drives, disk images, network shares, automounts) aren't part of this disk.
                if entry.isMountPoint || entry.deviceID != rootDevice {
                    mountPointCount.add(1, ordering: .relaxed)
                    continue
                }
                let childPath = Paths.join(item.path, entry.name)
                if options.excludedPaths.contains(childPath) { continue }
                childDirectories.append((entry.name, childPath))
                continue
            }
            let bytes = countedBytes(entry, in: item.path)
            ownBytes += bytes
            if entry.kind == .file { files += 1 }
            let isMedia = FileKinds.isMedia(name: entry.name)
            if isMedia { mediaBytes += bytes }
            if newest.map({ entry.modificationDate > $0 }) ?? true { newest = entry.modificationDate }
            if bytes >= options.bigFileFloor {
                big.append(BigFile(path: displayPath(Paths.join(item.path, entry.name)), bytes: bytes,
                                   modificationDate: entry.modificationDate, isMedia: isMedia))
            }
        }

        fileCount.add(Int(files), ordering: .relaxed)
        byteCount.add(Int(ownBytes), ordering: .relaxed)
        if !big.isEmpty { bigFiles.withLock { $0.append(contentsOf: big) } }

        var work: [WorkItem] = []
        work.reserveCapacity(childDirectories.count)
        drafts.withLock { drafts in
            let index = Int(item.index)
            drafts[index].ownBytes = ownBytes
            drafts[index].ownMediaBytes = mediaBytes
            drafts[index].ownFileCount = files
            drafts[index].markers = markers
            drafts[index].newestOwn = newest
            for child in childDirectories {
                let childIndex = Int32(drafts.count)
                drafts.append(Draft(name: child.name, parent: item.index))
                drafts[index].children.append(childIndex)
                work.append(WorkItem(index: childIndex, path: child.path))
            }
        }
        if !work.isEmpty {
            pending.add(work.count, ordering: .releasing)
            queue.withLock { $0.append(contentsOf: work) }
        }
    }

    private func countedBytes(_ entry: DirectoryEntry, in directory: String) -> Int64 {
        guard entry.kind == .file else { return entry.allocatedSize }
        if entry.isDataless {
            cloudOnlyCount.add(1, ordering: .relaxed)
            return 0
        }
        if entry.linkCount > 1, !seenLinks.withLock({ $0.insert(entry.fileID).inserted }) {
            return 0
        }
        if entry.mayShareBlocks, entry.cloneID != 0, !seenClones.withLock({ $0.insert(entry.cloneID).inserted }) {
            return reader.privateSize(ofFileAt: Paths.join(directory, entry.name)) ?? 0
        }
        return entry.allocatedSize
    }

    private func displayPath(_ absolute: String) -> String {
        guard options.displayRoot != options.rootPath, absolute.hasPrefix(options.rootPath) else { return absolute }
        let suffix = String(absolute.dropFirst(options.rootPath.count))
        if options.displayRoot == "/" { return suffix.isEmpty ? "/" : suffix }
        return options.displayRoot + suffix
    }

    func buildTree(elapsed: Duration) -> ScanTree {
        let drafts = drafts.withLock { $0 }
        let count = drafts.count
        var totalBytes = [Int64](repeating: 0, count: count)
        var totalMedia = [Int64](repeating: 0, count: count)
        var totalFiles = [Int64](repeating: 0, count: count)
        var newest = [Date?](repeating: nil, count: count)

        // Children always have higher indices than their parents, so one reverse pass aggregates.
        for index in stride(from: count - 1, through: 0, by: -1) {
            let draft = drafts[index]
            guard !draft.vanished else { continue }
            totalBytes[index] += draft.ownBytes
            totalMedia[index] += draft.ownMediaBytes
            totalFiles[index] += Int64(draft.ownFileCount)
            newest[index] = Self.later(newest[index], draft.newestOwn)
            if draft.parent >= 0 {
                let parent = Int(draft.parent)
                totalBytes[parent] += totalBytes[index]
                totalMedia[parent] += totalMedia[index]
                totalFiles[parent] += totalFiles[index]
                newest[parent] = Self.later(newest[parent], newest[index])
            }
        }

        let nodes = drafts.enumerated().map { index, draft in
            let children = draft.children
                .filter { !drafts[Int($0)].vanished }
                .sorted { totalBytes[Int($0)] > totalBytes[Int($1)] }
                .map(NodeID.init(raw:))
            return ScanNode(
                name: draft.name, parent: draft.parent >= 0 ? NodeID(raw: draft.parent) : nil, children: children,
                ownBytes: draft.ownBytes, ownMediaBytes: draft.ownMediaBytes, ownFileCount: draft.ownFileCount,
                markers: draft.markers, isInaccessible: draft.isInaccessible,
                totalBytes: totalBytes[index], totalMediaBytes: totalMedia[index], totalFileCount: totalFiles[index],
                newestOwnModification: draft.newestOwn, newestModification: newest[index])
        }

        let stats = ScanStats(
            files: fileCount.load(ordering: .relaxed), directories: directoryCount.load(ordering: .relaxed),
            inaccessibleDirectories: inaccessibleCount.load(ordering: .relaxed),
            mountPointsSkipped: mountPointCount.load(ordering: .relaxed),
            cloudOnlyFiles: cloudOnlyCount.load(ordering: .relaxed), elapsed: elapsed)
        return ScanTree(
            nodes: nodes, rootPath: options.rootPath, displayRoot: options.displayRoot,
            bigFiles: bigFiles.withLock { $0 }.sorted { $0.bytes > $1.bytes }, stats: stats)
    }

    private static func later(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (x?, y?): return max(x, y)
        default: return a ?? b
        }
    }
}
