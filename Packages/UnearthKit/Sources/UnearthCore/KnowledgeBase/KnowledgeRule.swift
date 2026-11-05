import Foundation

/// How careful the user needs to be. Ordered from least to most severe.
public enum SafetyLevel: String, Codable, Sendable, Comparable, CaseIterable {
    case safe, review, careful

    public static func < (lhs: SafetyLevel, rhs: SafetyLevel) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public enum CleanupSection: String, Codable, Sendable, CaseIterable {
    case junk, developer, largeFiles, manual
}

/// A cleanup that only the owning tool can do safely. Always permanent.
public struct ToolCommand: Codable, Sendable, Hashable {
    public let toolName: String
    public let executable: String
    public let arguments: [String]
    public let needsAdmin: Bool

    public init(toolName: String, executable: String, arguments: [String], needsAdmin: Bool = false) {
        self.toolName = toolName
        self.executable = executable
        self.arguments = arguments
        self.needsAdmin = needsAdmin
    }

    /// As shown to the user and written to the history.
    public var commandLine: String { ([executable] + arguments).joined(separator: " ") }
}

public enum CleanupAction: Sendable, Hashable {
    case trash
    case tool(ToolCommand)
    case report(guidance: String)
}

/// How an item's title is made from the folder name a wildcard matched.
public enum TitleStyle: String, Codable, Sendable {
    case fixed, appName, derivedData, huggingFace, folderName
}

public struct RulePattern: Codable, Sendable {
    public let path: String
    public let title: String?
    /// Bundle id or app name that must be closed before cleaning.
    public let owner: String?
    /// Overrides the rule's report guidance for this pattern.
    public let guidance: String?
}

/// The JSON form of an action. Tool actions never come from JSON, only from detectors.
public enum RuleAction: Codable, Sendable, Hashable {
    case trash
    case report(guidance: String)

    private enum CodingKeys: String, CodingKey { case type, guidance }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "trash": self = .trash
        case "report": self = .report(guidance: try container.decodeIfPresent(String.self, forKey: .guidance) ?? "")
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unsupported action \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .trash:
            try container.encode("trash", forKey: .type)
        case .report(let guidance):
            try container.encode("report", forKey: .type)
            try container.encode(guidance, forKey: .guidance)
        }
    }

    public var cleanupAction: CleanupAction {
        switch self {
        case .trash: .trash
        case .report(let guidance): .report(guidance: guidance)
        }
    }
}

public struct KnowledgeRule: Codable, Sendable, Identifiable {
    public let id: String
    public let section: CleanupSection
    public let group: String
    public let patterns: [RulePattern]
    public let titleStyle: TitleStyle
    public let what: String
    public let regrows: String
    public let safeToDelete: String
    public let safety: SafetyLevel
    public let action: RuleAction
    /// The first wildcard-matched folder name is the owning app (bundle id or name).
    public let ownerFromMatch: Bool
    /// Only offer items whose newest change is older than this.
    public let minAgeDays: Int?

    private enum CodingKeys: String, CodingKey {
        case id, section, group, patterns, titleStyle, what, regrows, safeToDelete, safety, action, ownerFromMatch, minAgeDays
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        section = try container.decode(CleanupSection.self, forKey: .section)
        group = try container.decode(String.self, forKey: .group)
        patterns = try container.decode([RulePattern].self, forKey: .patterns)
        titleStyle = try container.decodeIfPresent(TitleStyle.self, forKey: .titleStyle) ?? .fixed
        what = try container.decode(String.self, forKey: .what)
        regrows = try container.decode(String.self, forKey: .regrows)
        safeToDelete = try container.decode(String.self, forKey: .safeToDelete)
        safety = try container.decode(SafetyLevel.self, forKey: .safety)
        action = try container.decode(RuleAction.self, forKey: .action)
        ownerFromMatch = try container.decodeIfPresent(Bool.self, forKey: .ownerFromMatch) ?? false
        minAgeDays = try container.decodeIfPresent(Int.self, forKey: .minAgeDays)
    }
}
