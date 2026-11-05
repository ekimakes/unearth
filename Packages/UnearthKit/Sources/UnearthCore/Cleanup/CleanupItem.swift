import Foundation

/// The three plain-English answers shown with every item.
public struct Explanation: Sendable, Hashable {
    public let what: String
    public let regrows: String
    public let safeToDelete: String

    public init(what: String, regrows: String, safeToDelete: String) {
        self.what = what
        self.regrows = regrows
        self.safeToDelete = safeToDelete
    }
}

public enum BlockedReason: Sendable, Hashable {
    case appRunning(name: String)
    case neverTouch
    case needsFullDiskAccess
}

/// Something Unearth can clean, or explain how to clean.
public struct CleanupItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let ruleID: String
    public let section: CleanupSection
    public let group: String
    public let title: String
    public let subtitle: String?
    /// Display paths. Empty for tool items that aren't tied to one folder.
    public let paths: [String]
    public let bytes: Int64
    public let safety: SafetyLevel
    public let action: CleanupAction
    public let explanation: Explanation
    /// Bundle id or app name that must be closed first.
    public let owner: String?
    public var blockedReason: BlockedReason?

    public init(
        ruleID: String, section: CleanupSection, group: String, title: String, subtitle: String?, paths: [String],
        bytes: Int64, safety: SafetyLevel, action: CleanupAction, explanation: Explanation, owner: String?,
        blockedReason: BlockedReason?
    ) {
        // A tool item without a path is identified by its exact command, which names what it removes.
        let key: String = if let path = paths.first { path } else if case .tool(let command) = action { command.commandLine } else { title }
        self.id = "\(ruleID)|\(key)"
        self.ruleID = ruleID
        self.section = section
        self.group = group
        self.title = title
        self.subtitle = subtitle
        self.paths = paths
        self.bytes = bytes
        self.safety = safety
        self.action = action
        self.explanation = explanation
        self.owner = owner
        self.blockedReason = blockedReason
    }

    /// The same item pointing at other paths (used when display paths differ from real ones).
    public func withPaths(_ newPaths: [String]) -> CleanupItem {
        CleanupItem(ruleID: ruleID, section: section, group: group, title: title, subtitle: subtitle, paths: newPaths,
                    bytes: bytes, safety: safety, action: action, explanation: explanation, owner: owner,
                    blockedReason: blockedReason)
    }

    /// Run by the tool that owns the data, so it can't be undone.
    public var isPermanent: Bool {
        if case .tool = action { true } else { false }
    }

    public var isSelectableByDefault: Bool {
        safety == .safe && action == .trash && blockedReason == nil
    }

    /// Something the user picked themselves, like a folder in the Disk Map. Unearth can't vouch for it.
    public static func picked(path: String, bytes: Int64, what: String) -> CleanupItem {
        CleanupItem(
            ruleID: "manual", section: .manual, group: "Picked by you", title: (path as NSString).lastPathComponent,
            subtitle: nil, paths: [path], bytes: bytes, safety: .careful, action: .trash,
            explanation: Explanation(what: what, regrows: "Only if an app recreates it.", safeToDelete: "Only if you know what it is."),
            owner: nil, blockedReason: nil)
    }
}
