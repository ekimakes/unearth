import Foundation

public struct NodeID: Hashable, Sendable, Comparable {
    public let raw: Int32
    public init(raw: Int32) { self.raw = raw }
    public static func < (lhs: NodeID, rhs: NodeID) -> Bool { lhs.raw < rhs.raw }
}

/// One scanned directory. Sizes are counted bytes (see `DiskScanner` for the accounting rule).
public struct ScanNode: Sendable, Equatable {
    public let name: String
    public let parent: NodeID?
    /// Sorted by `totalBytes`, largest first.
    public let children: [NodeID]
    public let ownBytes: Int64
    public let ownMediaBytes: Int64
    public let ownFileCount: Int32
    public let markers: ProjectMarkers
    public let isInaccessible: Bool
    public let totalBytes: Int64
    public let totalMediaBytes: Int64
    public let totalFileCount: Int64
    public let newestOwnModification: Date?
    public let newestModification: Date?
}

public struct BigFile: Sendable, Hashable {
    /// Display path.
    public let path: String
    public let bytes: Int64
    public let modificationDate: Date
    public let isMedia: Bool
}

public struct ScanStats: Sendable, Equatable {
    public let files: Int
    public let directories: Int
    public let inaccessibleDirectories: Int
    public let mountPointsSkipped: Int
    public let cloudOnlyFiles: Int
    public let elapsed: Duration
}

/// The immutable result of a scan.
public final class ScanTree: Sendable, Identifiable {
    /// Different for every scan, so views can tell a rescan from the same tree.
    public let id = UUID()
    public let rootID: NodeID
    public let rootPath: String
    public let displayRoot: String
    /// Files at or above the scan's big-file floor, largest first.
    public let bigFiles: [BigFile]
    public let stats: ScanStats
    private let nodes: [ScanNode]

    init(nodes: [ScanNode], rootPath: String, displayRoot: String, bigFiles: [BigFile], stats: ScanStats) {
        self.nodes = nodes
        self.rootID = NodeID(raw: 0)
        self.rootPath = rootPath
        self.displayRoot = displayRoot
        self.bigFiles = bigFiles
        self.stats = stats
    }

    public var nodeCount: Int { nodes.count }

    public func node(_ id: NodeID) -> ScanNode { nodes[Int(id.raw)] }

    /// Display path ("/Users/me/…").
    public func path(of id: NodeID) -> String {
        var names: [String] = []
        var current: NodeID? = id
        while let cursor = current, cursor != rootID {
            let node = nodes[Int(cursor.raw)]
            names.append(node.name)
            current = node.parent
        }
        return names.reversed().reduce(displayRoot) { Paths.join($0, $1) }
    }

    /// The real path behind a display path ("/Users/me" → "/System/Volumes/Data/Users/me").
    public func realPath(forDisplayPath displayPath: String) -> String {
        guard displayRoot != rootPath else { return displayPath }
        let suffix = displayRoot == "/" ? displayPath : String(displayPath.dropFirst(displayRoot.count))
        return suffix == "/" ? rootPath : rootPath + suffix
    }

    /// The scanned folder at this display path, if there is one.
    public func node(atPath displayPath: String) -> ScanNode? {
        nodeID(forPath: displayPath).map(node)
    }

    public func nodeID(forPath displayPath: String) -> NodeID? {
        guard let names = namesBelowRoot(displayPath) else { return nil }
        var current = rootID
        for name in names {
            guard let next = child(of: current, named: name) else { return nil }
            current = next
        }
        return current
    }

    /// Whether the file at this display path sits in a code project: its folder, or one above it, has a
    /// project marker. Markers on `home` itself don't count, since a dotfiles repository or a stray
    /// package.json there doesn't make the whole home folder a project.
    public func isInsideCodeProject(_ displayPath: String, home: String? = nil) -> Bool {
        guard let names = namesBelowRoot(displayPath)?.dropLast() else { return false }
        let homeID = home.flatMap(nodeID(forPath:))
        var current = rootID
        if current != homeID, !node(current).markers.isEmpty { return true }
        for name in names {
            guard let next = child(of: current, named: name) else { return false }
            if next != homeID, !node(next).markers.isEmpty { return true }
            current = next
        }
        return false
    }

    /// The names leading from the scan's root to this display path, or nil when it's outside the scan.
    private func namesBelowRoot(_ displayPath: String) -> [String]? {
        let rootParts = Paths.comparableComponents(displayRoot)
        let parts = displayPath.split(separator: "/").map(String.init)
        guard parts.count >= rootParts.count,
              zip(parts, rootParts).allSatisfy({ Paths.isSameOrInside("/" + $0, "/" + $1) }) else { return nil }
        return Array(parts.dropFirst(rootParts.count))
    }

    /// Exact name match first, then the APFS-style comparison.
    public func child(of id: NodeID, named name: String) -> NodeID? {
        let children = nodes[Int(id.raw)].children
        if let exact = children.first(where: { nodes[Int($0.raw)].name == name }) { return exact }
        return children.first { Paths.isSameOrInside("/" + nodes[Int($0.raw)].name, "/" + name) }
    }

    /// This tree with one folder as it is now, until the next scan looks: folders inside it that `exists` no longer
    /// finds go with all they held, it adds up to the `bytes` just measured, and the folders above it follow.
    public func refreshing(folder displayPath: String, bytes: Int64, exists: (String) -> Bool) -> ScanTree {
        guard let id = nodeID(forPath: displayPath) else { return self }
        let gone = node(id).children.map(path(of:)).filter { !exists($0) }
        let left = gone.isEmpty ? self : removing(gone.map { (path: $0, bytes: 0) })
        var nodes = left.nodes
        let folder = nodes[Int(id.raw)]
        let change = bytes - folder.totalBytes
        // Empty is exact. Otherwise the scan's counts stand until it looks again: only the size was measured.
        let emptied = bytes == 0
        nodes[Int(id.raw)] = folder.changing(
            children: emptied ? [] : nil, ownBytes: max(0, bytes - (folder.totalBytes - folder.ownBytes)),
            ownMediaBytes: emptied ? 0 : nil, ownFileCount: emptied ? 0 : nil, totalBytes: bytes,
            totalMediaBytes: emptied ? 0 : nil, totalFileCount: emptied ? 0 : nil)
        var above = folder.parent
        while let current = above {
            let node = nodes[Int(current.raw)]
            nodes[Int(current.raw)] = node.changing(
                totalBytes: max(0, node.totalBytes + change),
                totalMediaBytes: emptied ? max(0, node.totalMediaBytes - folder.totalMediaBytes) : nil,
                totalFileCount: emptied ? max(0, node.totalFileCount - folder.totalFileCount) : nil)
            above = node.parent
        }
        above = folder.parent
        while let current = above {
            let node = nodes[Int(current.raw)]
            nodes[Int(current.raw)] = node.changing(children: node.children.sorted { nodes[Int($0.raw)].totalBytes > nodes[Int($1.raw)].totalBytes })
            above = node.parent
        }
        return ScanTree(nodes: nodes, rootPath: rootPath, displayRoot: displayRoot,
                        bigFiles: left.bigFiles.filter { !Paths.isSameOrInside($0.path, displayPath) || exists($0.path) }, stats: stats)
    }

    /// This tree with what just left the disk taken out, until the next scan looks. By display path, a folder goes
    /// with all it held and a file with the `bytes` it took; the folders above them get smaller by as much.
    public func removing(_ removed: [(path: String, bytes: Int64)]) -> ScanTree {
        var nodes = self.nodes
        var changed: Set<NodeID> = []
        func shrink(from folder: NodeID, bytes: Int64, media: Int64, files: Int64) {
            var current: NodeID? = folder
            while let id = current {
                let node = nodes[Int(id.raw)]
                nodes[Int(id.raw)] = node.changing(totalBytes: max(0, node.totalBytes - bytes),
                                                   totalMediaBytes: max(0, node.totalMediaBytes - media),
                                                   totalFileCount: max(0, node.totalFileCount - files))
                changed.insert(id)
                current = node.parent
            }
        }
        for (path, bytes) in removed {
            if let id = nodeID(forPath: path) {
                let node = nodes[Int(id.raw)]
                guard let parent = node.parent, nodes[Int(parent.raw)].children.contains(id) else { continue }
                nodes[Int(parent.raw)] = nodes[Int(parent.raw)].changing(children: nodes[Int(parent.raw)].children.filter { $0 != id })
                shrink(from: parent, bytes: node.totalBytes, media: node.totalMediaBytes, files: node.totalFileCount)
            } else if let id = nodeID(forPath: (path as NSString).deletingLastPathComponent) {
                let node = nodes[Int(id.raw)]
                let media = bigFiles.first { $0.path == path }?.isMedia == true ? bytes : 0
                nodes[Int(id.raw)] = node.changing(ownBytes: max(0, node.ownBytes - bytes), ownMediaBytes: max(0, node.ownMediaBytes - media),
                                                   ownFileCount: max(0, node.ownFileCount - 1))
                shrink(from: id, bytes: bytes, media: media, files: 1)
            }
        }
        for id in changed {
            let node = nodes[Int(id.raw)]
            nodes[Int(id.raw)] = node.changing(children: node.children.sorted { nodes[Int($0.raw)].totalBytes > nodes[Int($1.raw)].totalBytes })
        }
        var gone = RemovedPaths()
        gone.insert(contentsOf: removed.map(\.path))
        return ScanTree(nodes: nodes, rootPath: rootPath, displayRoot: displayRoot, bigFiles: bigFiles.filter { !gone.covers($0.path) },
                        stats: stats)
    }
}

extension ScanNode {
    fileprivate func changing(
        children: [NodeID]? = nil, ownBytes: Int64? = nil, ownMediaBytes: Int64? = nil, ownFileCount: Int32? = nil,
        totalBytes: Int64? = nil, totalMediaBytes: Int64? = nil, totalFileCount: Int64? = nil
    ) -> ScanNode {
        ScanNode(name: name, parent: parent, children: children ?? self.children, ownBytes: ownBytes ?? self.ownBytes,
                 ownMediaBytes: ownMediaBytes ?? self.ownMediaBytes, ownFileCount: ownFileCount ?? self.ownFileCount, markers: markers,
                 isInaccessible: isInaccessible, totalBytes: totalBytes ?? self.totalBytes,
                 totalMediaBytes: totalMediaBytes ?? self.totalMediaBytes, totalFileCount: totalFileCount ?? self.totalFileCount,
                 newestOwnModification: newestOwnModification, newestModification: newestModification)
    }
}
