import Foundation
@testable import UnearthCore

struct FakeApps: AppNameResolving {
    var names: [String: String] = [:]
    var running: Set<String> = []

    func appName(forBundleID bundleID: String) -> String? { names[bundleID] }
    func isRunning(_ owner: String) -> Bool { running.contains(owner) }
}

/// A fixture laid out like a Data volume: files go under `data/`, which scans as "/".
struct HomeFixture {
    static let home = "/Users/u"
    let fx: Fixture

    init() throws { fx = try Fixture() }

    /// `displayPath` like "/Users/u/Library/Caches/x/blob".
    @discardableResult
    func file(_ displayPath: String, bytes: Int, modified: Date? = nil) throws -> String {
        try fx.file("data" + displayPath, bytes: bytes, modified: modified)
    }

    func scan(bigFileFloor: Int64 = 50_000_000) async throws -> ScanTree {
        var options = ScanOptions(rootPath: fx.path("data"), displayRoot: "/")
        options.bigFileFloor = bigFileFloor
        return try await DiskScanner().scan(options)
    }

    func remove() { fx.remove() }
}

extension DetectionContext {
    static func test(
        tree: ScanTree, kb: KnowledgeBase, settings: CleanupSettings = CleanupSettings(), apps: FakeApps = FakeApps(),
        runner: FakeCommandRunner = FakeCommandRunner(), now: Date = Date()
    ) -> DetectionContext {
        DetectionContext(tree: tree, homePath: HomeFixture.home, now: now, settings: settings, apps: apps,
                         runner: runner, knowledgeBase: kb)
    }
}

extension KnowledgeBase {
    /// Builds a knowledge base from rule JSON objects, filling in copy fields.
    static func test(_ rules: [String], neverOffer: [String] = []) throws -> KnowledgeBase {
        let filled = rules.map { rule in
            "{\"what\": \"What.\", \"regrows\": \"Regrows.\", \"safeToDelete\": \"Safe.\", " + rule.dropFirst()
        }
        let neverOfferJSON = neverOffer.map { "\"\($0)\"" }.joined(separator: ",")
        let json = "{\"version\": 1, \"neverOffer\": [\(neverOfferJSON)], \"rules\": [\(filled.joined(separator: ","))]}"
        return try KnowledgeBase.decode(Data(json.utf8))
    }
}

extension CleanupItem {
    static func test(
        _ path: String, bytes: Int64 = 1_000, safety: SafetyLevel = .safe, action: CleanupAction = .trash,
        blocked: BlockedReason? = nil, section: CleanupSection = .junk
    ) -> CleanupItem {
        CleanupItem(
            ruleID: "test", section: section, group: "Group", title: (path as NSString).lastPathComponent, subtitle: nil,
            paths: [path], bytes: bytes, safety: safety, action: action,
            explanation: Explanation(what: "w", regrows: "r", safeToDelete: "s"), owner: nil, blockedReason: blocked)
    }
}
