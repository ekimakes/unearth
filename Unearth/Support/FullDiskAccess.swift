import AppKit
import Darwin

enum FullDiskAccess {
    /// Only apps with Full Disk Access can open the privacy database, so this is a reliable check.
    static func isGranted() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Opens System Settings at Privacy & Security › Full Disk Access.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
