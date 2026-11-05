import Darwin
import Foundation

/// Something an app leaves on the Mac besides itself.
public struct Leftover: Sendable, Hashable {
    public let path: String
    public let bytes: Int64
    /// In the home folder, so it can go to the Trash with the app. Others are only listed ("left behind").
    public let movable: Bool
}

/// An app in /Applications or ~/Applications.
public struct InstalledApp: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bundleID: String
    public let bytes: Int64
    /// When the app was last opened, as Spotlight knows it.
    public let lastUsed: Date?
    /// The folder it sits in inside Applications, like "Maxon Cinema 4D 2026": its vendor's uninstaller removes it.
    public let vendorFolder: String?
    /// One of Apple's own apps, which Unearth never offers to remove.
    public let isApple: Bool
    /// Moving it needs an administrator: it isn't the user's, or its folder isn't writable.
    public let needsAdmin: Bool
    public let leftovers: [Leftover]

    /// The app plus what can go to the Trash with it.
    public var movableBytes: Int64 {
        bytes + leftovers.filter(\.movable).reduce(0) { $0 + $1.bytes }
    }
}

public enum AppInventory {
    /// The apps in `folders`, directly or one folder down. `systemLibrary` is /Library outside of tests.
    public static func apps(
        in folders: [String], home: String, lastUsed: (String) -> Date?, systemLibrary: String = "/Library",
        reader: any DirectoryReading = BulkDirectoryReader()
    ) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for folder in folders {
            for entry in directories(in: folder, reader) {
                let path = Paths.join(folder, entry)
                if isApp(entry) {
                    apps += app(at: path, vendor: nil, home: home, lastUsed: lastUsed, systemLibrary: systemLibrary, reader)
                } else if !FileKinds.isPackage(name: entry) {
                    // Apps one folder down came with their vendor's folder (Utilities is Apple's own).
                    let vendor = entry == "Utilities" ? nil : (entry as NSString).deletingPathExtension
                    for inner in directories(in: path, reader) where isApp(inner) {
                        apps += app(at: Paths.join(path, inner), vendor: vendor, home: home, lastUsed: lastUsed,
                                    systemLibrary: systemLibrary, reader)
                    }
                }
            }
        }
        return apps
    }

    /// Apps not opened for `days`, largest first. Apple's apps and apps Spotlight has no date for never count.
    public static func unused(_ apps: [InstalledApp], now: Date, days: Int) -> [InstalledApp] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return apps.filter { !$0.isApple && ($0.lastUsed.map { $0 < cutoff } ?? false) }
            .sorted { $0.movableBytes != $1.movableBytes ? $0.movableBytes > $1.movableBytes : $0.path < $1.path }
    }

    private static func isApp(_ name: String) -> Bool { name.lowercased().hasSuffix(".app") }

    private static func directories(in folder: String, _ reader: any DirectoryReading) -> [String] {
        ((try? reader.entries(ofDirectoryAt: folder)) ?? [])
            .filter { $0.kind == .directory && !$0.name.hasPrefix(".") }
            .map(\.name)
            .sorted()
    }

    private static func app(
        at path: String, vendor: String?, home: String, lastUsed: (String) -> Date?, systemLibrary: String,
        _ reader: any DirectoryReading
    ) -> [InstalledApp] {
        guard let data = FileManager.default.contents(atPath: Paths.join(path, "Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String, !id.isEmpty else { return [] }
        var status = stat()
        let ownedByUser = lstat(path, &status) == 0 && status.st_uid == getuid()
        let folderWritable = access((path as NSString).deletingLastPathComponent, W_OK) == 0
        return [InstalledApp(
            path: path, name: ((path as NSString).lastPathComponent as NSString).deletingPathExtension, bundleID: id,
            bytes: DiskUsage.onDisk(path, reader: reader), lastUsed: lastUsed(path), vendorFolder: vendor,
            isApple: id.hasPrefix("com.apple.") || Paths.isSameOrInside(path, "/System"),
            needsAdmin: !ownedByUser || !folderWritable,
            leftovers: leftovers(of: id, home: home, systemLibrary: systemLibrary, reader))]
    }

    /// What the app keeps elsewhere, matched by its exact bundle id. Only the home folder's go with the app.
    static func leftovers(of id: String, home: String, systemLibrary: String, _ reader: any DirectoryReading) -> [Leftover] {
        let library = Paths.join(home, "Library")
        var movable = [
            "Application Support/\(id)", "Caches/\(id)", "Containers/\(id)", "Saved Application State/\(id).savedState",
            "Logs/\(id)", "HTTPStorages/\(id)", "WebKit/\(id)", "Application Scripts/\(id)", "Preferences/\(id).plist",
        ].map { Paths.join(library, $0) }
        movable += names(in: Paths.join(library, "Group Containers"), reader) { $0.hasSuffix("." + id) }
        var listed = [Paths.join(systemLibrary, "Application Support/\(id)")]
        for folder in ["LaunchAgents", "LaunchDaemons"] {
            listed += names(in: Paths.join(systemLibrary, folder), reader) {
                $0 == id + ".plist" || ($0.hasPrefix(id + ".") && $0.hasSuffix(".plist"))
            }
        }
        listed += names(in: Paths.join(systemLibrary, "PrivilegedHelperTools"), reader) { $0 == id || $0.hasPrefix(id + ".") }
        return movable.filter(exists).map { Leftover(path: $0, bytes: DiskUsage.onDisk($0, reader: reader), movable: true) }
            + listed.filter(exists).map { Leftover(path: $0, bytes: DiskUsage.onDisk($0, reader: reader), movable: false) }
    }

    private static func names(in folder: String, _ reader: any DirectoryReading, matching: (String) -> Bool) -> [String] {
        ((try? reader.entries(ofDirectoryAt: folder)) ?? []).map(\.name).filter(matching).sorted().map { Paths.join(folder, $0) }
    }

    private static func exists(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
    }
}
