import Foundation

/// Time Machine's local snapshots on the startup disk. Only `tmutil` can remove them.
public struct SnapshotDetector: CleanupDetector {
    public static let deleteCommand = ToolCommand(
        toolName: "Time Machine", executable: "/usr/bin/tmutil", arguments: ["deletelocalsnapshots", "/"], needsAdmin: true)

    private static let explanation = Explanation(
        what: "Backups Time Machine keeps on your Mac between backups to your backup disk.",
        regrows: "Yes. Time Machine makes new ones with each backup.",
        safeToDelete: "Yes, but you lose the hourly restore points stored on this Mac.")

    public init() {}

    public func detect(in context: DetectionContext) async -> [CleanupItem] {
        guard let result = try? await context.runner.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], environment: [:]),
              result.exitCode == 0 else { return [] }
        let count = String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n")
            .filter { $0.contains("com.apple.TimeMachine.") }
            .count
        guard count > 0 else { return [] }
        return [CleanupItem(
            ruleID: "time-machine-snapshots", section: .junk, group: "Time Machine",
            title: "Time Machine local snapshots (\(count))",
            subtitle: "Size unknown. macOS counts this as purgeable and removes it when space is needed.",
            paths: [], bytes: 0, safety: .review, action: .tool(Self.deleteCommand), explanation: Self.explanation,
            owner: nil, blockedReason: nil)]
    }
}
