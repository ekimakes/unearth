import Foundation

/// What the Safety Guard lets through for one uninstall: the app and its own preferences file.
public struct UninstallException: Sendable, Equatable {
    public let appPath: String
    public let preferencesPlist: String

    public init(appPath: String, preferencesPlist: String) {
        self.appPath = appPath
        self.preferencesPlist = preferencesPlist
    }
}

/// Moving an unused app and what it keeps in the home folder to the Trash.
public enum Uninstall {
    /// The app, then each of its movable leftovers. Nil for Apple's apps, and for apps in a vendor folder,
    /// which their vendor's uninstaller removes along with what it installed elsewhere.
    public static func items(for app: InstalledApp) -> [CleanupItem]? {
        guard !app.isApple, app.vendorFolder == nil else { return nil }
        let explanation = CollectionKind.unusedApps.explanation
        let group = CollectionKind.unusedApps.title
        let appItem = CleanupItem(
            ruleID: "uninstall-app", section: .manual, group: group, title: app.name, subtitle: nil, paths: [app.path],
            bytes: app.bytes, safety: .review, action: .trash, explanation: explanation, owner: app.bundleID,
            blockedReason: nil)
        return [appItem] + app.leftovers.filter(\.movable).map { leftover in
            let folder = ((leftover.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return CleanupItem(
                ruleID: "uninstall-leftover", section: .manual, group: group, title: "\(app.name): \(folder)", subtitle: nil,
                paths: [leftover.path], bytes: leftover.bytes, safety: .careful, action: .trash, explanation: explanation,
                owner: app.bundleID, blockedReason: nil)
        }
    }

    /// Moves the app first, then its leftovers, but only once the app itself has gone (or would have, in a dry
    /// run). A cancelled password prompt or a failed move must not strip an app that stays installed of its settings.
    public static func perform(_ items: [CleanupItem], engine: CleanupEngine) async -> CleanupOutcome {
        guard let app = items.first else { return CleanupOutcome(entries: [], failures: []) }
        let first = await engine.moveToTrash([app])
        guard first.entries.contains(where: { $0.state == .inTrash || $0.state == .completed }) else { return first }
        let rest = await engine.moveToTrash(Array(items.dropFirst()))
        return CleanupOutcome(entries: first.entries + rest.entries, failures: first.failures + rest.failures)
    }

    public static func exception(for app: InstalledApp, home: String) -> UninstallException {
        UninstallException(appPath: app.path, preferencesPlist: Paths.join(home, "Library/Preferences/\(app.bundleID).plist"))
    }
}
