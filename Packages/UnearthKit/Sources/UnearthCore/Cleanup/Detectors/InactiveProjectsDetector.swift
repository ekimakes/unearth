import Foundation

/// Rebuildable folders (node_modules, target, .venv, …) in coding projects nobody has changed lately.
public struct InactiveProjectsDetector: CleanupDetector {
    private static let artifactsByMarker: [(ProjectMarkers, [String])] = [
        (.packageJSON, ["node_modules", ".next"]),
        (.cargoToml, ["target"]),
        (.pythonProject, [".venv", "venv"]),
        (.podfile, ["Pods"]),
        (.gradle, ["build", ".gradle"]),
        (.swiftPackage, [".build"]),
    ]

    private static let explanation = Explanation(
        what: "Files a coding project downloads or builds, like node_modules. The project can recreate them.",
        regrows: "Yes, when you install or build the project again.",
        safeToDelete: "Yes, if you're not working on this project. Reinstall when you come back to it.")

    public init() {}

    public func detect(in context: DetectionContext) async -> [CleanupItem] {
        let tree = context.tree
        guard let homeID = tree.nodeID(forPath: context.homePath) else { return [] }
        let cutoff = context.now.addingTimeInterval(-Double(context.settings.inactiveProjectDays) * 86_400)
        var items: [CleanupItem] = []
        var stack = [homeID]

        while let id = stack.popLast() {
            let node = tree.node(id)
            let artifactNames = Set(Self.artifactsByMarker.filter { node.markers.contains($0.0) }.flatMap(\.1))

            if !artifactNames.isEmpty {
                let artifacts = node.children.filter { artifactNames.contains(tree.node($0).name) }
                let lastActivity = node.children
                    .filter { !artifacts.contains($0) }
                    .compactMap { tree.node($0).newestModification }
                    .reduce(node.newestOwnModification) { latest, date in max(latest ?? date, date) }
                if (lastActivity ?? .distantPast) < cutoff {
                    let days = Int(context.now.timeIntervalSince(lastActivity ?? .distantPast) / 86_400)
                    for artifact in artifacts {
                        let artifactNode = tree.node(artifact)
                        guard artifactNode.totalBytes >= CleanupSettings.smallItemThreshold else { continue }
                        let path = tree.path(of: artifact)
                        items.append(CleanupItem(
                            ruleID: "inactive-projects", section: .developer, group: "Build files in inactive projects",
                            title: "\(node.name) · \(artifactNode.name)",
                            subtitle: lastActivity == nil ? nil : "Untouched for \(days) days",
                            paths: [path], bytes: artifactNode.totalBytes, safety: .review, action: .trash,
                            explanation: Self.explanation, owner: nil,
                            blockedReason: context.isNeverTouch(path) ? .neverTouch : nil))
                    }
                }
            }

            for child in node.children {
                let name = tree.node(child).name
                if id == homeID && (name == "Library" || name == ".Trash") { continue }
                if name.hasPrefix(".") || name == "node_modules" || name.hasSuffix(".app") || artifactNames.contains(name) {
                    continue
                }
                stack.append(child)
            }
        }
        return items
    }
}
