import Darwin
import Foundation

/// What may be read: Unearth never reads a file whose contents are only in iCloud, since reading it downloads it.
/// The index's iCloud flag can be out of date (macOS evicts files at any time), so readers check right before.
public enum LocalFile {
    /// A regular file whose contents are on this Mac: not a link, not a folder, not only in iCloud.
    public static func isReadable(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFREG && info.st_flags & UInt32(SF_DATALESS) == 0
    }

    /// Whether the item's contents are only in iCloud right now.
    public static func isOnlyInICloud(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
    }
}

public enum RecognitionError: Error {
    /// Not a plain file on this Mac: a link, a folder, or a file only in iCloud.
    case notALocalFile
}
