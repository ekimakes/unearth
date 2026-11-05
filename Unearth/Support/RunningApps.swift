import AppKit
import UnearthCore

enum RunningApps {
    /// Whether an app that owns `owner` (a bundle id, app name or maker's folder name) is open right now.
    static func isRunning(_ owner: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            AppOwnership.owner(owner, matchesBundleID: $0.bundleIdentifier, name: $0.localizedName)
        }
    }
}
