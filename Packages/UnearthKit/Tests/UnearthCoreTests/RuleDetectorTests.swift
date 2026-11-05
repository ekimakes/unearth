import Foundation
import Testing
@testable import UnearthCore

struct RuleDetectorTests {
    static let appCaches = """
    {"id": "app-caches", "section": "junk", "group": "App caches", "patterns": [{"path": "~/Library/Caches/*"}],
     "titleStyle": "appName", "ownerFromMatch": true, "safety": "safe", "action": {"type": "trash"}}
    """
    static let chrome = """
    {"id": "browser-caches", "section": "junk", "group": "Browser caches",
     "patterns": [{"path": "~/Library/Caches/Google/Chrome", "title": "Google Chrome", "owner": "com.google.Chrome"}],
     "safety": "safe", "action": {"type": "trash"}}
    """

    @Test func producesItemPerMatchWithCopy() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/Library/Caches/com.alpha/blob", bytes: 2_000_000)
        try home.file("/Users/u/Library/Caches/com.beta/blob", bytes: 3_000_000)
        let tree = try await home.scan()
        let context = DetectionContext.test(tree: tree, kb: try .test([Self.appCaches]), apps: FakeApps(names: ["com.alpha": "Alpha"]))
        let items = await RuleDetector().detect(in: context).sorted { $0.bytes < $1.bytes }
        #expect(items.count == 2)
        let alpha = try #require(items.first)
        #expect(alpha.title == "Alpha")
        #expect(alpha.paths == ["/Users/u/Library/Caches/com.alpha"])
        #expect(alpha.bytes == tree.node(tree.nodeID(forPath: "/Users/u/Library/Caches/com.alpha")!).totalBytes)
        #expect(alpha.id == "app-caches|/Users/u/Library/Caches/com.alpha")
        #expect(alpha.explanation == Explanation(what: "What.", regrows: "Regrows.", safeToDelete: "Safe."))
        #expect(alpha.safety == .safe)
        #expect(alpha.action == .trash)
        #expect(alpha.section == .junk)
        #expect(alpha.owner == "com.alpha")
        #expect(items.last?.title == "com.beta")
    }

    @Test func specificRuleClaimsBeforeGeneric() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/Library/Caches/Google/Chrome/Default/Cache/data", bytes: 2_000_000)
        try home.file("/Users/u/Library/Caches/Google/Other/data", bytes: 2_000_000)
        let tree = try await home.scan()
        let items = await RuleDetector().detect(in: .test(tree: tree, kb: try .test([Self.chrome, Self.appCaches])))
        #expect(items.map(\.title) == ["Google Chrome"])
        #expect(items.first?.owner == "com.google.Chrome")
    }

    @Test func marksNeverTouch() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/Library/Caches/com.alpha/blob", bytes: 2_000_000)
        let tree = try await home.scan()
        var settings = CleanupSettings()
        settings.neverTouch = ["/Users/u/Library/Caches/com.alpha"]
        let items = await RuleDetector().detect(in: .test(tree: tree, kb: try .test([Self.appCaches]), settings: settings))
        #expect(items.first?.blockedReason == .neverTouch)
        #expect(items.first?.isSelectableByDefault == false)
    }

    @Test func skipsNeverOffer() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/Library/Caches/com.apple.bird/blob", bytes: 2_000_000)
        try home.file("/Users/u/Library/Caches/com.alpha/blob", bytes: 2_000_000)
        let tree = try await home.scan()
        let kb = try KnowledgeBase.test([Self.appCaches], neverOffer: ["~/Library/Caches/com.apple.bird"])
        let items = await RuleDetector().detect(in: .test(tree: tree, kb: kb))
        #expect(items.map(\.title) == ["com.alpha"])
    }

    @Test func blocksRunningOwner() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/Library/Caches/com.foo/blob", bytes: 2_000_000)
        let tree = try await home.scan()
        let apps = FakeApps(names: ["com.foo": "Foo"], running: ["com.foo"])
        let items = await RuleDetector().detect(in: .test(tree: tree, kb: try .test([Self.appCaches]), apps: apps))
        #expect(items.first?.blockedReason == .appRunning(name: "Foo"))
    }

    @Test func rollsUpSmallItems() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        for i in 0..<5 { try home.file("/Users/u/Library/Caches/com.small\(i)/blob", bytes: 10_000) }
        try home.file("/Users/u/Library/Caches/com.big/blob", bytes: 2_000_000)
        let tree = try await home.scan()
        let items = await RuleDetector().detect(in: .test(tree: tree, kb: try .test([Self.appCaches])))
        #expect(items.count == 2)
        let rolled = try #require(items.first { $0.paths.count == 5 })
        #expect(rolled.title == "5 smaller items")
        #expect(rolled.bytes == rolled.paths.reduce(0) { $0 + tree.node(tree.nodeID(forPath: $1)!).totalBytes })
    }

    @Test func respectsMinAge() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        let now = Date()
        try home.file("/Users/u/Library/Caches/com.fresh/blob", bytes: 2_000_000, modified: now)
        try home.file("/Users/u/Library/Caches/com.stale/blob", bytes: 2_000_000, modified: now.addingTimeInterval(-10 * 86_400))
        let tree = try await home.scan()
        let rule = Self.appCaches.replacingOccurrences(of: "\"safety\"", with: "\"minAgeDays\": 3, \"safety\"")
        let items = await RuleDetector().detect(in: .test(tree: tree, kb: try .test([rule]), now: now))
        #expect(items.map(\.title) == ["com.stale"])
    }

    @Test func titlesFromWildcardsAndLiterals() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/Library/Application Support/Claude/Code Cache/js/x", bytes: 2_000_000)
        try home.file("/Users/u/Library/Developer/Xcode/DerivedData/Unearth-abcdefghijklmnopqrstuvwxyzab/Build/x", bytes: 2_000_000)
        try home.file("/Users/u/.cache/huggingface/hub/models--openai--whisper-large/blobs/x", bytes: 2_000_000)
        let tree = try await home.scan()
        let rules = [
            #"{"id": "e", "section": "junk", "group": "g", "patterns": [{"path": "~/Library/Application Support/*/Code Cache"}], "titleStyle": "folderName", "ownerFromMatch": true, "safety": "safe", "action": {"type": "trash"}}"#,
            #"{"id": "d", "section": "developer", "group": "g", "patterns": [{"path": "~/Library/Developer/Xcode/DerivedData/*"}], "titleStyle": "derivedData", "safety": "safe", "action": {"type": "trash"}}"#,
            #"{"id": "h", "section": "developer", "group": "g", "patterns": [{"path": "~/.cache/huggingface/hub/models--*"}], "titleStyle": "huggingFace", "safety": "review", "action": {"type": "trash"}}"#,
        ]
        let items = await RuleDetector().detect(in: .test(tree: tree, kb: try .test(rules)))
        #expect(Set(items.map(\.title)) == ["Claude · Code Cache", "Unearth", "openai/whisper-large"])
        #expect(items.first { $0.title == "Claude · Code Cache" }?.owner == "Claude")
    }

    @Test func titleTemplatesInsertTheMatchedName() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/Library/Caches/Adobe/After Effects/26.0/Disk Cache/x", bytes: 2_000_000)
        let tree = try await home.scan()
        let rule = #"{"id": "ae", "section": "junk", "group": "g", "patterns": [{"path": "~/Library/Caches/Adobe/After Effects/*", "title": "After Effects {name} disk cache"}], "titleStyle": "folderName", "safety": "safe", "action": {"type": "trash"}}"#
        let items = await RuleDetector().detect(in: .test(tree: tree, kb: try .test([rule])))
        #expect(items.map(\.title) == ["After Effects 26.0 disk cache"])
    }

    /// Found on a real Mac: 221 GB of After Effects disk cache, mostly from versions no longer installed.
    @Test func bundledRulesSplitAfterEffectsCacheByVersion() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/Library/Caches/Adobe/After Effects/26.0/Disk Cache/x", bytes: 2_000_000)
        try home.file("/Users/u/Library/Caches/Adobe/After Effects/22.6/Disk Cache/x", bytes: 3_000_000)
        let tree = try await home.scan()
        let items = await RuleDetector().detect(in: .test(tree: tree, kb: try KnowledgeBase.bundled()))
        #expect(Set(items.map(\.title)) == ["After Effects 26.0 disk cache", "After Effects 22.6 disk cache"])
        #expect(items.allSatisfy { $0.owner == "com.adobe.AfterEffects.application" && $0.safety == .safe })
        let running = FakeApps(running: ["com.adobe.AfterEffects.application"])
        let blocked = await RuleDetector().detect(in: .test(tree: tree, kb: try KnowledgeBase.bundled(), apps: running))
        #expect(blocked.allSatisfy { $0.blockedReason != nil })
    }

    /// Mail opens attachments from this folder, so a file signed or edited after opening may exist only here.
    @Test func bundledRulesLeaveMailDownloadsForReview() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/A1B2/contract.pdf", bytes: 2_000_000)
        let tree = try await home.scan()
        let items = await RuleDetector().detect(in: .test(tree: tree, kb: try KnowledgeBase.bundled()))
        let mail = try #require(items.first { $0.ruleID == "mail-downloads" })
        #expect(mail.safety == .review)
        #expect(!mail.isSelectableByDefault)
        #expect(mail.explanation.what.contains("edited or signed"))
    }

    /// Homebrew downloads its formula list again (going online) when it's missing, so it stays.
    @Test func bundledRulesKeepHomebrewsFormulaList() async throws {
        let api = "/Users/u/Library/Caches/Homebrew/api"
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file(api + "/formula.jws.json", bytes: 3_000_000)
        try home.file("/Users/u/Library/Caches/Homebrew/bootsnap/x", bytes: 2_000_000)
        let onlyLists = await RuleDetector().detect(in: .test(tree: try await home.scan(), kb: try KnowledgeBase.bundled()))
        #expect(!onlyLists.flatMap(\.paths).contains { Paths.isSameOrInside(api, $0) })

        try home.file("/Users/u/Library/Caches/Homebrew/downloads/abc--wget.bottle.tar.gz", bytes: 2_000_000)
        let items = await RuleDetector().detect(in: .test(tree: try await home.scan(), kb: try KnowledgeBase.bundled()))
        #expect(items.flatMap(\.paths).contains("/Users/u/Library/Caches/Homebrew/downloads"))
        #expect(!items.flatMap(\.paths).contains { Paths.isSameOrInside(api, $0) })
    }

    @Test func reportsUnreadableKnownFolders() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        let locked = try home.file("/Users/u/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/a.pdf", bytes: 2_000_000)
        let folder = (locked as NSString).deletingLastPathComponent
        chmod(folder, 0o000)
        defer { chmod(folder, 0o755) }
        let tree = try await home.scan()
        let rule = #"{"id": "mail", "section": "junk", "group": "g", "patterns": [{"path": "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", "title": "Mail downloads"}], "safety": "safe", "action": {"type": "trash"}}"#
        let items = await RuleDetector().detect(in: .test(tree: tree, kb: try .test([rule])))
        #expect(items.first?.blockedReason == .needsFullDiskAccess)
    }
}
