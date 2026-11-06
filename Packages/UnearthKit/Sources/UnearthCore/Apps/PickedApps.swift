import Foundation

/// Apps picked by hand: on the Apps page, on a collection's page or in the Disk Map. The Safety Guard refuses anything
/// in Applications, so each one goes the way an uninstall does: on its own, with its own exception. Only the app moves,
/// because that's all the confirmation names; what it keeps in the home folder stays.
public enum PickedApps {
    /// The paths the user picked that may be apps. `AppInventory.app(at:in:home:)` says which really are. What a
    /// cleanup rule found is never one of them.
    public static func candidates(in items: [CleanupItem]) -> [String] {
        items.filter { ($0.ruleID == CleanupItem.pickedRuleID || $0.ruleID.hasPrefix("collection-")) && $0.paths.count == 1 }
            .map { $0.paths[0] }
            .filter { $0.lowercased().hasSuffix(".app") }
    }

    /// Why this app stays where it is, or nil if it can go.
    public static func refusal(for app: InstalledApp) -> String? {
        if app.isApple { return "It's one of Apple's own apps, so Unearth leaves it alone." }
        if let vendor = app.vendorFolder { return "Use \(vendor)'s uninstaller. It also removes what it installed elsewhere." }
        return nil
    }

    /// Moves `items` to the Trash: those in `apps`, by path, each through `appEngine`, and the rest through `engine`.
    /// `progress` hears how many of `items` have been dealt with, after each one.
    public static func moveToTrash(
        _ items: [CleanupItem], apps: [String: InstalledApp], isRunning: @Sendable (String) -> Bool, engine: CleanupEngine,
        appEngine: @Sendable (InstalledApp) -> CleanupEngine, progress: @Sendable (Int) -> Void = { _ in }
    ) async -> CleanupOutcome {
        let picked = items.compactMap { item in item.paths.count == 1 ? apps[item.paths[0]] : nil }
        let others = items.filter { item in item.paths.count != 1 || apps[item.paths[0]] == nil }
        let rest = await engine.moveToTrash(others, progress: progress)
        var entries = rest.entries
        var failures = rest.failures
        for (done, app) in picked.enumerated() {
            defer { progress(others.count + done + 1) }
            if let reason = refusal(for: app) ?? (isRunning(app.bundleID) ? "Quit \(app.name) first, then try again." : nil) {
                failures.append(CleanupFailure(title: app.name, path: app.path, reason: reason))
                continue
            }
            guard let item = Uninstall.items(for: app)?.first else { continue }
            let moved = await appEngine(app).moveToTrash([item])
            entries += moved.entries
            failures += moved.failures
        }
        return CleanupOutcome(entries: entries, failures: failures)
    }
}
