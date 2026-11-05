import AppKit
import Synchronization
import UnearthCore

/// App names from bundle ids, and which apps were open when the plan was made.
final class AppNameResolver: AppNameResolving, Sendable {
    private let running: [(bundleID: String?, name: String?)]
    /// Bundle id → app name ("" when no app is installed for it).
    private let names = Mutex<[String: String]>([:])

    private init(running: [(bundleID: String?, name: String?)]) {
        self.running = running
    }

    @MainActor static func current() -> AppNameResolver {
        AppNameResolver(running: NSWorkspace.shared.runningApplications.map { ($0.bundleIdentifier, $0.localizedName) })
    }

    func appName(forBundleID bundleID: String) -> String? {
        if let known = names.withLock({ $0[bundleID] }) { return known.isEmpty ? nil : known }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
        names.withLock { $0[bundleID] = name ?? "" }
        return name
    }

    func isRunning(_ owner: String) -> Bool {
        running.contains { AppOwnership.owner(owner, matchesBundleID: $0.bundleID, name: $0.name) }
    }
}
