import Foundation

/// Turns knowledge-base rules into items, using only the scan tree.
public struct RuleDetector: CleanupDetector {
    public init() {}

    public func detect(in context: DetectionContext) async -> [CleanupItem] {
        let tree = context.tree
        let home = context.homePath
        let neverOffer = context.knowledgeBase.neverOffer.map { PathPattern($0, homePath: home).components }
            .map { "/" + $0.joined(separator: "/") }
        var claimed: [String] = []
        var items: [CleanupItem] = []

        for rule in context.knowledgeBase.rules {
            var smallPaths: [String] = []
            var smallBytes: Int64 = 0

            for pattern in rule.patterns {
                let matcher = PathPattern(pattern.path, homePath: home)
                for id in tree.nodes(matching: matcher) {
                    let node = tree.node(id)
                    let path = tree.path(of: id)
                    let overlaps = { (other: String) in Paths.isSameOrInside(path, other) || Paths.isSameOrInside(other, path) }
                    if neverOffer.contains(where: overlaps) || claimed.contains(where: overlaps) { continue }
                    if let days = rule.minAgeDays, let newest = node.newestModification,
                       newest > context.now.addingTimeInterval(-Double(days) * 86_400) { continue }

                    let names = path.split(separator: "/").map(String.init)
                    let owner = pattern.owner ?? (rule.ownerFromMatch ? Self.firstWildcardName(matcher, names) : nil)
                    var blocked: BlockedReason?
                    if node.isInaccessible {
                        // Only named, known folders are worth reporting; unreadable generic matches are skipped.
                        guard pattern.title != nil else { continue }
                        blocked = .needsFullDiskAccess
                    } else if node.totalBytes == 0 {
                        continue
                    }
                    if context.isNeverTouch(path) {
                        blocked = .neverTouch
                    } else if blocked == nil, let owner, context.apps.isRunning(owner) {
                        blocked = .appRunning(name: context.apps.appName(forBundleID: owner) ?? owner)
                    }
                    claimed.append(path)

                    let isSmall = node.totalBytes < CleanupSettings.smallItemThreshold && blocked != .needsFullDiskAccess
                    if isSmall {
                        // Tiny items are rolled up; tiny blocked ones aren't worth a row.
                        if blocked == nil {
                            smallPaths.append(path)
                            smallBytes += node.totalBytes
                        }
                        continue
                    }
                    items.append(item(rule: rule, pattern: pattern, title: Self.title(rule, pattern, matcher, names, context.apps),
                                      paths: [path], bytes: node.totalBytes, owner: owner, blocked: blocked))
                }
            }

            if smallPaths.count == 1, let only = smallPaths.first, let pattern = rule.patterns.first {
                let matcher = PathPattern(pattern.path, homePath: home)
                let names = only.split(separator: "/").map(String.init)
                items.append(item(rule: rule, pattern: pattern, title: Self.title(rule, pattern, matcher, names, context.apps),
                                  paths: [only], bytes: smallBytes, owner: nil, blocked: nil))
            } else if smallPaths.count > 1, let pattern = rule.patterns.first {
                items.append(item(rule: rule, pattern: pattern, title: "\(smallPaths.count) smaller items",
                                  paths: smallPaths, bytes: smallBytes, owner: nil, blocked: nil))
            }
        }
        return items
    }

    private func item(
        rule: KnowledgeRule, pattern: RulePattern, title: String, paths: [String], bytes: Int64, owner: String?,
        blocked: BlockedReason?
    ) -> CleanupItem {
        var action = rule.action.cleanupAction
        if case .report = action, let guidance = pattern.guidance, !guidance.isEmpty {
            action = .report(guidance: guidance)
        }
        return CleanupItem(
            ruleID: rule.id, section: rule.section, group: rule.group, title: title, subtitle: nil, paths: paths,
            bytes: bytes, safety: rule.safety, action: action,
            explanation: Explanation(what: rule.what, regrows: rule.regrows, safeToDelete: rule.safeToDelete),
            owner: owner, blockedReason: blocked)
    }

    // MARK: - Titles

    private static func isWildcard(_ component: String) -> Bool {
        component.contains { "*?[".contains($0) }
    }

    static func firstWildcardName(_ pattern: PathPattern, _ names: [String]) -> String? {
        pattern.components.indices.first { isWildcard(pattern.components[$0]) }.flatMap { $0 < names.count ? names[$0] : nil }
    }

    /// A fixed title wins; "{name}" in it becomes the styled matched name ("After Effects {name} disk cache").
    /// Otherwise style the wildcard-matched name; when the pattern ends in a literal folder
    /// ("…/*/Code Cache"), append it: "Claude · Code Cache".
    static func title(
        _ rule: KnowledgeRule, _ pattern: RulePattern, _ matcher: PathPattern, _ names: [String], _ apps: any AppNameResolving
    ) -> String {
        if let title = pattern.title {
            guard title.contains("{name}"), let last = matcher.components.indices.last(where: { isWildcard(matcher.components[$0]) }),
                  last < names.count else { return title }
            return title.replacingOccurrences(of: "{name}", with: styled(names[last], rule.titleStyle, apps))
        }
        let wildcards = matcher.components.indices.filter { isWildcard(matcher.components[$0]) }
        guard let first = wildcards.first, let last = names.indices.last else { return rule.group }
        if wildcards.contains(last) { return styled(names[last], rule.titleStyle, apps) }
        return styled(names[first], rule.titleStyle, apps) + " · " + names[last]
    }

    static func styled(_ name: String, _ style: TitleStyle, _ apps: any AppNameResolving) -> String {
        switch style {
        case .fixed, .folderName:
            return name.hasSuffix(".xcarchive") ? String(name.dropLast(".xcarchive".count)) : name
        case .appName:
            guard name.contains("."), !name.contains(" ") else { return name }
            return apps.appName(forBundleID: name) ?? name
        case .derivedData:
            guard let range = name.range(of: "-[a-z]{28}$", options: .regularExpression) else { return name }
            return String(name[..<range.lowerBound])
        case .huggingFace:
            for prefix in ["models--", "datasets--", "spaces--"] where name.hasPrefix(prefix) {
                return name.dropFirst(prefix.count).replacingOccurrences(of: "--", with: "/")
            }
            return name
        }
    }
}
