import Foundation

/// Installers and archives sitting in ~/Downloads.
public struct DownloadsDetector: CleanupDetector {
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]
    private static let archiveSuffixes = [".tar.gz", ".zip", ".tar", ".gz", ".tgz", ".rar", ".7z"]

    private static let installers = Explanation(
        what: "An installer you downloaded. Once the app is installed, it usually isn't needed.",
        regrows: "No. You'd download the installer again if you need it.",
        safeToDelete: "Usually. Keep it if you might reinstall and can't easily download it again.")
    private static let archives = Explanation(
        what: "A compressed file you downloaded.",
        regrows: "No.",
        safeToDelete: "Yes, if you've already opened it or no longer need what's inside.")

    public init() {}

    public func detect(in context: DetectionContext) async -> [CleanupItem] {
        let downloads = Paths.join(context.homePath, "Downloads")
        let real = context.tree.realPath(forDisplayPath: downloads)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: real) else { return [] }
        let folders = Set(names.filter { isDirectory(Paths.join(real, $0)) })

        return names.compactMap { name -> CleanupItem? in
            let lowered = name.lowercased()
            let isInstaller = Self.installerExtensions.contains((lowered as NSString).pathExtension)
            let archiveSuffix = Self.archiveSuffixes.first { lowered.hasSuffix($0) }
            guard isInstaller || archiveSuffix != nil else { return nil }

            let path = Paths.join(downloads, name)
            let bytes = size(of: Paths.join(real, name), displayPath: path, tree: context.tree)
            guard bytes >= CleanupSettings.smallItemThreshold else { return nil }

            var subtitle: String?
            if let archiveSuffix, !isInstaller, folders.contains(String(name.dropLast(archiveSuffix.count))) {
                subtitle = "Already unzipped"
            }
            return CleanupItem(
                ruleID: isInstaller ? "downloads-installers" : "downloads-archives", section: .junk,
                group: isInstaller ? "Installers in Downloads" : "Archives in Downloads", title: name, subtitle: subtitle,
                paths: [path], bytes: bytes, safety: .review, action: .trash,
                explanation: isInstaller ? Self.installers : Self.archives, owner: nil,
                blockedReason: context.isNeverTouch(path) ? .neverTouch : nil)
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Bundles (old-style .pkg folders) come from the tree; plain files from the file system.
    private func size(of realPath: String, displayPath: String, tree: ScanTree) -> Int64 {
        if let node = tree.node(atPath: displayPath) { return node.totalBytes }
        let values = try? URL(fileURLWithPath: realPath).resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? 0)
    }
}
