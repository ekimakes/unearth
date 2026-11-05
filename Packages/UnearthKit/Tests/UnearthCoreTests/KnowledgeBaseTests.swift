import Foundation
import Testing
@testable import UnearthCore

struct KnowledgeBaseTests {
    @Test func bundledDecodes() throws {
        let kb = try KnowledgeBase.bundled()
        #expect(kb.version >= 1)
        #expect(kb.rules.count >= 20)
        #expect(!kb.neverOffer.isEmpty)
    }

    @Test func idsAreUnique() throws {
        let ids = try KnowledgeBase.bundled().rules.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyRuleHasCopy() throws {
        for rule in try KnowledgeBase.bundled().rules {
            for text in [rule.what, rule.regrows, rule.safeToDelete] {
                #expect(!text.isEmpty, "\(rule.id)")
                #expect(text.count <= 160, "\(rule.id): \(text)")
            }
            #expect(!rule.group.isEmpty)
            #expect(!rule.patterns.isEmpty)
        }
    }

    @Test func genericCacheRulesComeLast() throws {
        let rules = try KnowledgeBase.bundled().rules
        let generic = try #require(rules.firstIndex { $0.id == "app-caches" })
        for (index, rule) in rules.enumerated() where rule.id != "app-caches" {
            let specific = rule.patterns.contains { $0.path.hasPrefix("~/Library/Caches/") && $0.path != "~/Library/Caches/*" }
            if specific { #expect(index < generic, "\(rule.id) must come before app-caches") }
        }
    }

    @Test func reportRulesHaveGuidance() throws {
        for rule in try KnowledgeBase.bundled().rules {
            if case .report(let guidance) = rule.action.cleanupAction {
                #expect(!guidance.isEmpty || rule.patterns.allSatisfy { !($0.guidance ?? "").isEmpty }, "\(rule.id)")
            }
        }
    }

    @Test func noToolActionsInJSON() throws {
        let json = """
        {"version": 1, "neverOffer": [], "rules": [{"id": "x", "section": "junk", "group": "g",
          "patterns": [{"path": "~/x"}], "what": "w", "regrows": "r", "safeToDelete": "s", "safety": "safe",
          "action": {"type": "tool"}}]}
        """
        #expect(throws: (any Error).self) { try KnowledgeBase.decode(Data(json.utf8)) }
    }

    @Test func optionalFieldsDefault() throws {
        let json = """
        {"version": 1, "neverOffer": [], "rules": [{"id": "x", "section": "developer", "group": "g",
          "patterns": [{"path": "~/x", "title": "X"}], "what": "w", "regrows": "r", "safeToDelete": "s",
          "safety": "review", "action": {"type": "report", "guidance": "do it"}}]}
        """
        let rule = try #require(try KnowledgeBase.decode(Data(json.utf8)).rules.first)
        #expect(rule.titleStyle == .fixed)
        #expect(rule.ownerFromMatch == false)
        #expect(rule.minAgeDays == nil)
        #expect(rule.action.cleanupAction == .report(guidance: "do it"))
        #expect(rule.safety == .review)
    }

    @Test func safetyLevelsOrderBySeverity() {
        #expect(SafetyLevel.safe < .review)
        #expect(SafetyLevel.review < .careful)
    }
}
