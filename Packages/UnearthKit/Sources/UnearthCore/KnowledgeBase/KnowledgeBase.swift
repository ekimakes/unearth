import Foundation

/// The curated list of known space users, shipped with the app. Rules are tried in file order,
/// so specific rules come before generic ones.
public struct KnowledgeBase: Codable, Sendable {
    public let version: Int
    /// Paths that are never offered for cleanup, even when a rule matches them.
    public let neverOffer: [String]
    public let rules: [KnowledgeRule]

    public static func bundled() throws -> KnowledgeBase {
        guard let url = Bundle.module.url(forResource: "KnowledgeBase", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> KnowledgeBase {
        try JSONDecoder().decode(KnowledgeBase.self, from: data)
    }
}
