import Foundation

/// iPhone and iPad backups made with Finder, one item per device backup.
public struct DeviceBackupsDetector: CleanupDetector {
    private static let explanation = Explanation(
        what: "A full backup of an iPhone or iPad, made when it was synced with this Mac.",
        regrows: "Only when you back up that device to this Mac again.",
        safeToDelete: "Only if you don't need this backup, for example because the device backs up to iCloud.")

    public init() {}

    public func detect(in context: DetectionContext) async -> [CleanupItem] {
        let mobileSync = Paths.join(context.homePath, "Library/Application Support/MobileSync")
        let backups = Paths.join(mobileSync, "Backup")
        let tree = context.tree

        guard let folder = tree.node(atPath: backups) ?? tree.node(atPath: mobileSync) else { return [] }
        if folder.isInaccessible {
            return [item(title: "iPhone & iPad backups", subtitle: nil, path: backups, bytes: 0,
                         blocked: .needsFullDiskAccess)]
        }
        guard let backupsID = tree.nodeID(forPath: backups) else { return [] }

        return tree.node(backupsID).children.compactMap { id in
            let node = tree.node(id)
            guard node.totalBytes > 0 else { return nil }
            let path = tree.path(of: id)
            let info = readInfo(at: Paths.join(tree.realPath(forDisplayPath: path), "Info.plist"))
            let name = info?["Device Name"] as? String ?? info?["Display Name"] as? String ?? "Device backup"
            let subtitle = (info?["Last Backup Date"] as? Date).map {
                "Backed up \($0.formatted(date: .abbreviated, time: .omitted))"
            }
            return item(title: name, subtitle: subtitle, path: path, bytes: node.totalBytes,
                        blocked: context.isNeverTouch(path) ? .neverTouch : nil)
        }
    }

    private func readInfo(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private func item(title: String, subtitle: String?, path: String, bytes: Int64, blocked: BlockedReason?) -> CleanupItem {
        CleanupItem(
            ruleID: "device-backups", section: .junk, group: "iPhone & iPad backups", title: title, subtitle: subtitle,
            paths: [path], bytes: bytes, safety: .review, action: .trash, explanation: Self.explanation, owner: nil,
            blockedReason: blocked)
    }
}
