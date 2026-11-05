import Foundation

/// How much the Trash holds. Unearth only reports it: emptying the Trash is the user's call, in Finder.
public struct TrashReportDetector: CleanupDetector {
    private static let explanation = Explanation(
        what: "Files you already moved to the Trash. They take up space until the Trash is emptied.",
        regrows: "Yes, whenever you move more files to the Trash.",
        safeToDelete: "Only empty it once you're sure you don't need anything in it.")

    public init() {}

    public func detect(in context: DetectionContext) async -> [CleanupItem] {
        let path = Paths.join(context.homePath, ".Trash")
        guard let node = context.tree.node(atPath: path) else { return [] }
        guard node.isInaccessible || node.totalBytes > 0 else { return [] }
        return [CleanupItem(
            ruleID: "trash", section: .junk, group: "Trash", title: "Trash", subtitle: nil, paths: [path],
            bytes: node.totalBytes, safety: .safe,
            action: .report(guidance: "Empty the Trash in Finder to get this space back."),
            explanation: Self.explanation, owner: nil, blockedReason: node.isInaccessible ? .needsFullDiskAccess : nil)]
    }
}
