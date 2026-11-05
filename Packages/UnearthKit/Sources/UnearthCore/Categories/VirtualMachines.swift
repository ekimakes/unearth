import Foundation

/// Where virtual machines and containers keep their disks. Removing one of those files loses everything
/// inside, so Unearth leaves them to the app that made them.
public enum VirtualMachines {
    /// "~" is the home folder.
    public static let locations = [
        "~/Library/Containers/com.docker.docker", "~/Library/Containers/com.utmapp.UTM",
        "~/Library/Group Containers/HUAQ24HBR6.dev.orbstack", "~/.orbstack", "~/.colima", "~/.lima",
        "~/.local/share/containers", "~/Parallels", "~/Virtual Machines.localized",
    ]
    private static let diskExtensions: Set<String> = ["vmdk", "vdi", "vhd", "vhdx", "qcow2", "hdd", "hds"]

    public static func isDisk(_ path: String, homePath: String) -> Bool {
        if diskExtensions.contains((path as NSString).pathExtension.lowercased()) { return true }
        return locations.contains { location in
            Paths.isSameOrInside(path, "/" + PathPattern(location, homePath: homePath).components.joined(separator: "/"))
        }
    }
}
