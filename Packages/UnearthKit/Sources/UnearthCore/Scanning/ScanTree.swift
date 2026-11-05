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
}
