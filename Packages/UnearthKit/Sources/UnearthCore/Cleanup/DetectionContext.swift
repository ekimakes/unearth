import Foundation

/// Looks up app names and whether an app is open. The app target implements it with AppKit.
public protocol AppNameResolving: Sendable {
    func appName(forBundleID bundleID: String) -> String?
    /// `owner` is a bundle id or an app name.
    func isRunning(_ owner: String) -> Bool
}

/// Everything a detector may read. Detectors never walk the disk again when the tree has the answer.
public struct DetectionContext: Sendable {
    public let tree: ScanTree
    public let homePath: String
    public let now: Date
    public let settings: CleanupSettings
    public let apps: any AppNameResolving
    public let runner: any CommandRunning
    public let knowledgeBase: KnowledgeBase

    public init(
        tree: ScanTree, homePath: String, now: Date, settings: CleanupSettings, apps: any AppNameResolving,
        runner: any CommandRunning, knowledgeBase: KnowledgeBase
    ) {
        self.tree = tree
        self.homePath = homePath
        self.now = now
        self.settings = settings
        self.apps = apps
        self.runner = runner
        self.knowledgeBase = knowledgeBase
    }

    /// Whether the user protected this path (or something inside it).
    public func isNeverTouch(_ path: String) -> Bool {
        settings.neverTouch.contains { Paths.isSameOrInside(path, $0) || Paths.isSameOrInside($0, path) }
    }
}

public protocol CleanupDetector: Sendable {
    func detect(in context: DetectionContext) async -> [CleanupItem]
}
