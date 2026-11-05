import Foundation

/// A folder where a System Data bucket starts, with the bytes inside it that belong to that bucket.
public struct BucketContributor: Sendable, Hashable {
    public let node: NodeID
    public let bytes: Int64
}

/// The startup disk split into Overview segments, with System Data split into buckets.
/// Every byte of used space lands in exactly one segment.
public struct StorageBreakdown: Sendable {
    public let total: Int64
    public let used: Int64
    public let free: Int64
    public let purgeable: Int64
    /// Sums exactly to `used`.
    public let segments: [StorageCategory: Int64]
    /// Sums exactly to `segments[.systemData]`.
    public let systemData: [SystemDataBucket: Int64]
    /// Largest first.
    public let bucketContributors: [SystemDataBucket: [BucketContributor]]
    /// The folders behind each category, largest first: where its rules matched (/Applications,
    /// ~/Library/Developer…), and for the home folder's documents and media, each of the home folder's folders.
    /// None for System Data (see `bucketContributors`) or macOS, which is a volume of its own.
    public let categoryContributors: [StorageCategory: [BucketContributor]]
    /// Bytes the scan counted beyond what the volumes report (diagnostics only).
    public let overcount: Int64

    public static func compute(
        tree: ScanTree, volumes: VolumeInventory, homePath: String, rules: [CategoryRule]? = nil
    ) -> StorageBreakdown {
        var tally = Tally()
        tally.attribute(tree: tree, rules: rules ?? CategoryRules.standard(homePath: homePath))

        var overcount: Int64 = 0
        var notIdentified: Int64 = 0
        let scanned = tree.node(tree.rootID).totalBytes
        if let data = volumes.volume(withRole: "Data") {
            let remainder = data.capacityInUse - scanned
            if remainder >= 0 { notIdentified += remainder } else { overcount -= remainder }
        }
        for volume in volumes.container.volumes {
            let roles = Set(volume.roles)
            if roles.contains("System") {
                tally.segments[.macOS, default: 0] += volume.capacityInUse
            } else if roles.contains("Data") {
                continue
            } else if roles.contains("VM") {
                tally.buckets[.swap, default: 0] += volume.capacityInUse
            } else if !roles.isDisjoint(with: ["Preboot", "Recovery", "Update"]) {
                tally.buckets[.systemSupport, default: 0] += volume.capacityInUse
            } else {
                tally.segments[.other, default: 0] += volume.capacityInUse
            }
        }
        let overhead = volumes.used - volumes.container.volumes.reduce(0) { $0 + $1.capacityInUse }
        if overhead >= 0 { notIdentified += overhead } else { overcount -= overhead }
        tally.buckets[.notIdentified, default: 0] += notIdentified
        tally.reconcile(to: volumes.used)

        let contributors = tally.contributors
            .filter { $0.bytes > 0 }
            .reduce(into: [SystemDataBucket: [BucketContributor]]()) { result, entry in
                result[entry.bucket, default: []].append(BucketContributor(node: entry.node, bytes: entry.bytes))
            }
            .mapValues { $0.sorted { $0.bytes > $1.bytes } }
        let folders = tally.folderBytes
            .filter { $0.value > 0 }
            .reduce(into: [StorageCategory: [BucketContributor]]()) { result, entry in
                result[entry.key.category, default: []].append(BucketContributor(node: entry.key.node, bytes: entry.value))
            }
            .mapValues { $0.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.node < $1.node } }

        return StorageBreakdown(
            total: volumes.container.capacity, used: volumes.used, free: volumes.container.free,
            purgeable: volumes.purgeable, segments: tally.segments, systemData: tally.buckets,
            bucketContributors: contributors, categoryContributors: folders, overcount: overcount)
    }
}

private struct Tally {
    struct Assignment: Equatable {
        var category: StorageCategory
        var bucket: SystemDataBucket?
    }

    struct Contributor {
        let node: NodeID
        let bucket: SystemDataBucket
        var bytes: Int64
    }

    struct FolderShare: Hashable {
        let node: NodeID
        let category: StorageCategory
    }

    var segments = Dictionary(uniqueKeysWithValues: StorageCategory.allCases.map { ($0, Int64(0)) })
    var buckets = Dictionary(uniqueKeysWithValues: SystemDataBucket.allCases.map { ($0, Int64(0)) })
    var contributors: [Contributor] = []
    var folderBytes: [FolderShare: Int64] = [:]

    /// Depth-first walk carrying the rules that can still match below each folder.
    mutating func attribute(tree: ScanTree, rules: [CategoryRule]) {
        struct Frame {
            let node: NodeID
            let depth: Int
            let candidates: [Int]
            let parent: Assignment
            let parentContributor: Int
            /// The folder this one's bytes count toward in `folderBytes`.
            let folder: NodeID?
            /// The parent is the home folder (or another documents root), so this folder counts on its own.
            let startsFolder: Bool
        }

        let rootDepth = tree.displayRoot.split(separator: "/").count
        let rootParts = tree.displayRoot.split(separator: "/").map(String.init)
        let rootCandidates = rules.indices.filter { index in
            let pattern = rules[index].pattern
            return pattern.components.count >= rootDepth
                && rootParts.indices.allSatisfy { pattern.componentMatches($0, rootParts[$0]) }
        }
        let rootRule = rootCandidates.last { rules[$0].pattern.components.count == rootDepth }
        let rootAssignment = rootRule.map { Assignment(category: rules[$0].category, bucket: rules[$0].bucket) }
            ?? Assignment(category: .systemData, bucket: .otherSystem)
        let rootFolder = rootAssignment.category == .systemData ? nil : tree.rootID
        add(tree.node(tree.rootID), to: rootAssignment, contributor: -1, folder: rootFolder)

        var stack = tree.node(tree.rootID).children.map {
            Frame(node: $0, depth: rootDepth + 1,
                  candidates: rootCandidates.filter { rules[$0].pattern.components.count > rootDepth },
                  parent: rootAssignment, parentContributor: -1, folder: rootFolder,
                  startsFolder: rootRule != nil && rootAssignment.category == .documents)
        }

        while let frame = stack.popLast() {
            let node = tree.node(frame.node)
            let componentIndex = frame.depth - 1
            let matching = frame.candidates.filter { rules[$0].pattern.componentMatches(componentIndex, node.name) }
            var assignment = frame.parent
            var isBoundary = false
            if let exact = matching.last(where: { rules[$0].pattern.components.count == frame.depth }) {
                assignment = Assignment(category: rules[exact].category, bucket: rules[exact].bucket)
                isBoundary = true
            }

            var contributor = frame.parentContributor
            if assignment.category == .systemData {
                if contributor < 0 || isBoundary || assignment != frame.parent {
                    contributors.append(Contributor(node: frame.node, bucket: assignment.bucket ?? .otherSystem, bytes: 0))
                    contributor = contributors.count - 1
                }
            } else {
                contributor = -1
            }
            var folder = frame.folder
            if assignment.category != .systemData, isBoundary || frame.startsFolder { folder = frame.node }
            add(node, to: assignment, contributor: contributor, folder: folder)

            let below = matching.filter { rules[$0].pattern.components.count > frame.depth }
            for child in node.children {
                stack.append(Frame(node: child, depth: frame.depth + 1, candidates: below,
                                   parent: assignment, parentContributor: contributor, folder: folder,
                                   startsFolder: isBoundary && assignment.category == .documents))
            }
        }
    }

    private mutating func add(_ node: ScanNode, to assignment: Assignment, contributor: Int, folder: NodeID?) {
        switch assignment.category {
        case .documents:
            segments[.photosVideos, default: 0] += node.ownMediaBytes
            segments[.documents, default: 0] += node.ownBytes - node.ownMediaBytes
            if let folder {
                folderBytes[FolderShare(node: folder, category: .photosVideos), default: 0] += node.ownMediaBytes
                folderBytes[FolderShare(node: folder, category: .documents), default: 0] += node.ownBytes - node.ownMediaBytes
            }
        case .systemData:
            buckets[assignment.bucket ?? .otherSystem, default: 0] += node.ownBytes
            if contributor >= 0 { contributors[contributor].bytes += node.ownBytes }
        default:
            segments[assignment.category, default: 0] += node.ownBytes
            if let folder { folderBytes[FolderShare(node: folder, category: assignment.category), default: 0] += node.ownBytes }
        }
    }

    /// Makes System Data equal its buckets and all segments equal `used`. Only an overcount
    /// (the scan saw more than the volumes report) makes this move bytes, taking from the largest.
    mutating func reconcile(to used: Int64) {
        segments[.systemData] = buckets.values.reduce(0, +)
        var excess = segments.values.reduce(0, +) - used
        if excess < 0 {
            buckets[.notIdentified, default: 0] -= excess
            segments[.systemData, default: 0] -= excess
            return
        }
        for category in segments.keys.sorted(by: { segments[$0]! > segments[$1]! }) where excess > 0 {
            if category == .systemData {
                for bucket in buckets.keys.sorted(by: { buckets[$0]! > buckets[$1]! }) where excess > 0 {
                    let take = min(excess, buckets[bucket]!)
                    buckets[bucket]! -= take
                    segments[.systemData]! -= take
                    excess -= take
                }
            } else {
                let take = min(excess, segments[category]!)
                segments[category]! -= take
                excess -= take
            }
        }
    }
}
