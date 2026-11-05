import Foundation

/// Where the Disk Map is pointed, kept as display paths. Node ids only mean something inside one
/// scan, and the map stays open across rescans.
public struct DiskMapState: Sendable, Equatable {
    public private(set) var focusPath: String?
    /// The folder waiting for the user to confirm Move to Trash.
    public private(set) var trashPath: String?

    public init() {}

    /// The focused folder in `tree`, or the top when that folder is gone.
    public func focus(in tree: ScanTree) -> NodeID {
        focusPath.flatMap(tree.nodeID(forPath:)) ?? tree.rootID
    }

    public mutating func focus(on id: NodeID, in tree: ScanTree) {
        focusPath = id == tree.rootID ? nil : tree.path(of: id)
    }

    public mutating func askToTrash(_ id: NodeID, in tree: ScanTree) {
        trashPath = tree.path(of: id)
    }

    public mutating func cancelTrash() {
        trashPath = nil
    }

    /// The picked folder, looked up again in `tree`; nil when it's no longer there.
    public func trashItem(in tree: ScanTree) -> CleanupItem? {
        guard let trashPath, let id = tree.nodeID(forPath: trashPath), id != tree.rootID else { return nil }
        return .picked(path: trashPath, bytes: tree.node(id).totalBytes, what: "A folder you picked in the Disk Map.")
    }
}
