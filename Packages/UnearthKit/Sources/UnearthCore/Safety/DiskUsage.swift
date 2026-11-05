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

    /// A path on an external drive that isn't connected right now: offline, not deleted.
    public static func isOnDisconnectedVolume(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/" + parts[1])
    }
}
