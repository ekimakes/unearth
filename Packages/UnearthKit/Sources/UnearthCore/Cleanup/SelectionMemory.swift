import Foundation

/// The boxes the user ticked or unticked themselves. Replanning (a filter change, the rescan after a
/// cleanup) rebuilds every item, and only items the user never touched should get their default.
public struct SelectionMemory: Sendable, Equatable {
    private var ticked: Set<CleanupItem.ID> = []
    private var unticked: Set<CleanupItem.ID> = []

    public init() {}

    public mutating func record(_ id: CleanupItem.ID, selected: Bool) {
        if selected {
            ticked.insert(id)
            unticked.remove(id)
        } else {
            unticked.insert(id)
            ticked.remove(id)
        }
    }

    /// The selection for a new plan. Choices about items that left the plan are forgotten, so an item that
    /// comes back later starts from its default again.
    public mutating func apply(to plan: CleanupPlan) -> Set<CleanupItem.ID> {
        let present = Set(plan.items.map(\.id))
        ticked.formIntersection(present)
        unticked.formIntersection(present)
        let tickable = Set(plan.items.filter { $0.action == .trash && $0.blockedReason == nil }.map(\.id))
        return plan.defaultSelection().union(ticked.intersection(tickable)).subtracting(unticked)
    }
}
