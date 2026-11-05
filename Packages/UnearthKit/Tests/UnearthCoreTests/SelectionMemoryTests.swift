import Testing
@testable import UnearthCore

/// A replan (a filter change, the rescan after a cleanup) rebuilds the plan. The user's own ticks must survive it.
struct SelectionMemoryTests {
    static let a = CleanupItem.test("/Users/u/Library/Caches/a")
    static let b = CleanupItem.test("/Users/u/Library/Caches/b")
    static let review = CleanupItem.test("/Users/u/Library/Containers/mail", safety: .review)

    @Test func keepsWhatTheUserUntickedAcrossReplans() {
        var memory = SelectionMemory()
        #expect(memory.apply(to: CleanupPlan(items: [Self.a, Self.b])) == [Self.a.id, Self.b.id])
        memory.record(Self.a.id, selected: false)
        #expect(memory.apply(to: CleanupPlan(items: [Self.a, Self.b])) == [Self.b.id])
    }

    @Test func keepsWhatTheUserTicked() {
        var memory = SelectionMemory()
        memory.record(Self.review.id, selected: true)
        #expect(memory.apply(to: CleanupPlan(items: [Self.a, Self.review])) == [Self.a.id, Self.review.id])
    }

    @Test func newItemsGetTheirDefault() {
        var memory = SelectionMemory()
        memory.record(Self.a.id, selected: false)
        #expect(memory.apply(to: CleanupPlan(items: [Self.a, Self.b, Self.review])) == [Self.b.id])
    }

    @Test func forgetsItemsThatLeftThePlan() {
        var memory = SelectionMemory()
        memory.record(Self.review.id, selected: true)
        memory.record(Self.a.id, selected: false)
        _ = memory.apply(to: CleanupPlan(items: [Self.b]))
        #expect(memory.apply(to: CleanupPlan(items: [Self.a, Self.b, Self.review])) == [Self.a.id, Self.b.id])
    }

    @Test func neverSelectsBlockedOrToolItems() {
        var memory = SelectionMemory()
        let blocked = CleanupItem.test("/Users/u/Library/Caches/a", blocked: .appRunning(name: "A"))
        let tool = CleanupItem.test("/Users/u/x", action: .tool(ToolCommand(toolName: "T", executable: "/bin/t", arguments: [])))
        memory.record(blocked.id, selected: true)
        memory.record(tool.id, selected: true)
        #expect(memory.apply(to: CleanupPlan(items: [blocked, tool])).isEmpty)
    }
}
