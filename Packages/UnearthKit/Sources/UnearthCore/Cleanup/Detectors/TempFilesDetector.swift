import Darwin
import Foundation

/// Leftovers in this user's temporary folder that nothing has touched for a few days.
public struct TempFilesDetector: CleanupDetector {
    private let tempDirectory: String
    private let minAgeDays: Int

    private static let explanation = Explanation(
        what: "Temporary files apps created while working and didn't clean up.",
        regrows: "Apps create new temporary files as they run.",
        safeToDelete: "Yes. Only files nothing has touched for 3 days or more are included.")

    /// `tempDirectory` is a display path; by default this user's temporary folder.
    public init(tempDirectory: String = TempFilesDetector.defaultTempDirectory(), minAgeDays: Int = 3) {
        self.tempDirectory = tempDirectory
        self.minAgeDays = minAgeDays
    }

    public static func defaultTempDirectory() -> String {
        guard let resolved = realpath(NSTemporaryDirectory(), nil) else { return NSTemporaryDirectory() }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func detect(in context: DetectionContext) async -> [CleanupItem] {
        let tree = context.tree
        let real = tree.realPath(forDisplayPath: tempDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: real) else { return [] }
        let cutoff = context.now.addingTimeInterval(-Double(minAgeDays) * 86_400)

        var paths: [String] = []
        var bytes: Int64 = 0
        for name in names.sorted() {
            let path = Paths.join(tempDirectory, name)
            guard !context.isNeverTouch(path) else { continue }
            let size: Int64
            let newest: Date?
            if let node = tree.node(atPath: path) {
                size = node.totalBytes
                newest = node.newestModification
            } else {
                let values = try? URL(fileURLWithPath: Paths.join(real, name))
                    .resourceValues(forKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey])
                size = Int64(values?.totalFileAllocatedSize ?? 0)
                newest = values?.contentModificationDate
            }
            guard size > 0, (newest ?? .distantPast) < cutoff else { continue }
            paths.append(path)
            bytes += size
        }
        guard !paths.isEmpty else { return [] }
        return [CleanupItem(
            ruleID: "temp-files", section: .junk, group: "Temporary files", title: "Old temporary files", subtitle: nil,
            paths: paths, bytes: bytes, safety: .safe, action: .trash, explanation: Self.explanation, owner: nil,
            blockedReason: nil)]
    }
}
