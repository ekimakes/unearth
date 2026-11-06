import Foundation

public struct CleanupPlan: Sendable {
    public let items: [CleanupItem]

    public init(items: [CleanupItem]) {
        self.items = items
    }

    /// This plan with one row swapped for `item` where it stands, or taken out when there's none.
    public func replacing(_ id: CleanupItem.ID, with item: CleanupItem?) -> CleanupPlan {
        CleanupPlan(items: items.flatMap { $0.id == id ? (item.map { [$0] } ?? []) : [$0] })
    }

    /// Largest first.
    public func items(in section: CleanupSection) -> [CleanupItem] {
        items.filter { $0.section == section }.sorted { $0.bytes > $1.bytes }
    }

    public func defaultSelection() -> Set<CleanupItem.ID> {
        Set(items.filter(\.isSelectableByDefault).map(\.id))
    }

    /// Bytes of the selected items, skipping any item that sits inside another selected item.
    public func totalBytes(of selection: Set<CleanupItem.ID>) -> Int64 {
        let chosen = items.filter { selection.contains($0.id) }
        return chosen.reduce(0) { total, item in
            let nested = item.paths.first.map { path in
                chosen.contains { other in
                    other.id != item.id && other.paths.contains { $0 != path && Paths.isSameOrInside(path, $0) }
                }
            } ?? false
            return nested ? total : total + item.bytes
        }
    }
}

/// Runs every detector and merges what they found.
public struct CleanupPlanner: Sendable {
    private let detectors: [any CleanupDetector]

    public init(detectors: [any CleanupDetector]) {
        self.detectors = detectors
    }

    public static func standard() -> CleanupPlanner {
        CleanupPlanner(detectors: [
            RuleDetector(), DownloadsDetector(), DeviceBackupsDetector(), TempFilesDetector(), TrashReportDetector(),
            SnapshotDetector(), InactiveProjectsDetector(), SimulatorDetector(), HomebrewDetector(),
        ])
    }

    public func plan(_ context: DetectionContext) async -> CleanupPlan {
        let found = await withTaskGroup(of: (Int, [CleanupItem]).self) { group in
            for (index, detector) in detectors.enumerated() {
                group.addTask { (index, await detector.detect(in: context)) }
            }
            var results = [[CleanupItem]](repeating: [], count: detectors.count)
            for await (index, items) in group { results[index] = items }
            return results.flatMap { $0 }
        }
        return CleanupPlan(items: Self.removeNested(found))
    }

    /// When one item sits inside another, the outer one wins.
    static func removeNested(_ items: [CleanupItem]) -> [CleanupItem] {
        let ordered = items.enumerated().sorted { a, b in
            let depthA = a.element.paths.first.map { $0.split(separator: "/").count } ?? 0
            let depthB = b.element.paths.first.map { $0.split(separator: "/").count } ?? 0
            return depthA == depthB ? a.offset < b.offset : depthA < depthB
        }
        var kept: [CleanupItem] = []
        for (_, item) in ordered {
            if let first = item.paths.first,
               kept.contains(where: { $0.paths.contains { Paths.isSameOrInside(first, $0) } }) {
                continue
            }
            kept.append(item)
        }
        return kept
    }
}
