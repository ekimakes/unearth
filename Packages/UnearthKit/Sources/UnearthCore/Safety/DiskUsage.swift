import Darwin
import Foundation

/// The space things take on this Mac: what the Trash gives back once it's emptied.
public enum DiskUsage {
    /// Bytes `path` occupies on this Mac. iCloud-only files take none; folders add up what's inside.
    public static func onDisk(_ path: String, reader: any DirectoryReading = BulkDirectoryReader()) -> Int64 {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey])
        else { return 0 }
        guard values.isDirectory == true, values.isSymbolicLink != true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        var folders = [path]
        while let folder = folders.popLast() {
            for entry in (try? reader.entries(ofDirectoryAt: folder)) ?? [] {
                if entry.kind == .directory {
                    if !entry.isMountPoint { folders.append(Paths.join(folder, entry.name)) }
                } else {
                    total += entry.allocatedSize
                }
            }
        }
        return total
    }

    /// When `path` last changed, in nanoseconds: for a folder, when something last went in or came out. This costs
    /// next to nothing, and needs no permission to look inside.
    public static func lastChange(of path: String) -> Int64? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }

    /// A path on an external drive that isn't connected right now: offline, not deleted.
    public static func isOnDisconnectedVolume(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/" + parts[1])
    }
}
