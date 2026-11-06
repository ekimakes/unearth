import Foundation

/// How much the Trash holds. Unearth only reports it: emptying the Trash is the user's call, in Finder.
public struct TrashReportDetector: CleanupDetector {
    public static let ruleID = "trash"
    private static let explanation = Explanation(
        what: "Files you already moved to the Trash. They take up space until the Trash is emptied.",
        regrows: "Yes, whenever you move more files to the Trash.",
        safeToDelete: "Only empty it once you're sure you don't need anything in it.")

    public init() {}

    public func detect(in context: DetectionContext) async -> [CleanupItem] {
        Self.item(in: context.tree, homePath: context.homePath).map { [$0] } ?? []
    }

    /// The Trash's row, or nil while it holds nothing.
    public static func item(in tree: ScanTree, homePath: String) -> CleanupItem? {
        let path = Paths.join(homePath, ".Trash")
        guard let node = tree.node(atPath: path), node.isInaccessible || node.totalBytes > 0 else { return nil }
        return CleanupItem(
            ruleID: ruleID, section: .junk, group: "Trash", title: "Trash", subtitle: nil, paths: [path],
            bytes: node.totalBytes, safety: .safe,
            action: .report(guidance: "Empty the Trash in Finder to get this space back."),
            explanation: explanation, owner: nil, blockedReason: node.isInaccessible ? .needsFullDiskAccess : nil)
    }
}
