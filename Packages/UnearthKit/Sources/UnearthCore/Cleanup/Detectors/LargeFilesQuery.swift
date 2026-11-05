import Foundation

/// Big files the user hasn't opened in a while, from the scan's list of large files.
public struct LargeFilesQuery: Sendable {
    private let minimumBytes: Int64
    private let notOpenedForDays: Int?
    private let now: Date
    private let homePath: String
    private let lastUsed: @Sendable (String) -> Date?

    private static let explanation = Explanation(
        what: "A large file you haven't opened in a while.",
        regrows: "No. This is your file, not something an app recreates.",
        safeToDelete: "Only if you no longer need it. Check it with Quick Look first.")

    /// `lastUsed` looks up when a file was last opened (Spotlight); the modification date stands in when it can't tell.
    /// Only files in the home folder and /Users/Shared are offered.
    public init(
        minimumBytes: Int64, notOpenedForDays: Int?, now: Date, homePath: String,
        lastUsed: @escaping @Sendable (String) -> Date?
    ) {
        self.minimumBytes = minimumBytes
        self.notOpenedForDays = notOpenedForDays
        self.now = now
        self.homePath = homePath
        self.lastUsed = lastUsed
    }

    /// Leaves out what isn't the user's to delete file by file: pieces of apps, libraries and document
    /// packages, virtual machine disks, and anything `safetyGuard` (on display paths) would refuse.
    public func items(from tree: ScanTree, safetyGuard: SafetyGuard) -> [CleanupItem] {
        let cutoff = notOpenedForDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
        let roots = [homePath, "/Users/Shared"]
        return tree.bigFiles.compactMap { file -> CleanupItem? in
            guard file.bytes >= minimumBytes,
                  roots.contains(where: { Paths.isSameOrInside(file.path, $0) }),
                  !FileKinds.isInsidePackage(file.path),
                  !VirtualMachines.isDisk(file.path, homePath: homePath),
                  safetyGuard.ruleViolation(for: file.path) == nil else { return nil }
            let opened = lastUsed(file.path)
            if let cutoff, (opened ?? file.modificationDate) >= cutoff { return nil }
            let subtitle = opened.map { "Last opened \($0.formatted(date: .abbreviated, time: .omitted))" }
                ?? "Modified \(file.modificationDate.formatted(date: .abbreviated, time: .omitted))"
            return CleanupItem(
                ruleID: "large-files", section: .largeFiles, group: file.isMedia ? "Photos & videos" : "Other large files",
                title: (file.path as NSString).lastPathComponent, subtitle: subtitle, paths: [file.path], bytes: file.bytes,
                safety: .review, action: .trash, explanation: Self.explanation, owner: nil, blockedReason: nil)
        }
    }
}
