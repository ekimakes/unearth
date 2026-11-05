import Foundation
import Testing
@testable import UnearthCore

struct CleanupPlannerTests {
    struct FixedDetector: CleanupDetector {
        let items: [CleanupItem]
        func detect(in context: DetectionContext) async -> [CleanupItem] { items }
    }

    @Test func defaultSelectionIsSafeTrashUnblockedOnly() {
        let tool = ToolCommand(toolName: "Xcode", executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"])
        let plan = CleanupPlan(items: [
            .test("/a/safe"),
            .test("/a/review", safety: .review),
            .test("/a/tool", action: .tool(tool)),
            .test("/a/report", action: .report(guidance: "do it")),
            .test("/a/blocked", blocked: .appRunning(name: "Foo")),
        ])
        #expect(plan.defaultSelection() == ["test|/a/safe"])
    }

    @Test func totalCountsNestedOnce() {
        let plan = CleanupPlan(items: [.test("/x", bytes: 10), .test("/x/y", bytes: 5), .test("/z", bytes: 1)])
        #expect(plan.totalBytes(of: ["test|/x", "test|/x/y", "test|/z"]) == 11)
    }

    @Test func withPathsKeepsEverythingElse() {
        let item = CleanupItem.test("/Users/demo/Library/Caches/x", bytes: 7, safety: .review)
        let moved = item.withPaths(["/tmp/demo/Users/demo/Library/Caches/x"])
        #expect(moved.paths == ["/tmp/demo/Users/demo/Library/Caches/x"])
        #expect(moved.title == item.title)
        #expect(moved.bytes == 7)
        #expect(moved.safety == .review)
        #expect(moved.ruleID == item.ruleID)
    }

    @Test func itemsInSectionAreLargestFirst() {
        let plan = CleanupPlan(items: [.test("/a", bytes: 1), .test("/b", bytes: 3), .test("/c", bytes: 2, section: .developer)])
        #expect(plan.items(in: .junk).map(\.bytes) == [3, 1])
    }

    @Test func dedupesNestedAcrossDetectors() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/x/blob", bytes: 10)
        let tree = try await home.scan()
        let planner = CleanupPlanner(detectors: [
            FixedDetector(items: [.test("/Users/u/Library/Caches/com.a/sub", bytes: 5)]),
            FixedDetector(items: [.test("/Users/u/Library/Caches/com.a", bytes: 9)]),
        ])
        let plan = await planner.plan(.test(tree: tree, kb: try .test([])))
        #expect(plan.items.map(\.paths) == [["/Users/u/Library/Caches/com.a"]])
    }
}
