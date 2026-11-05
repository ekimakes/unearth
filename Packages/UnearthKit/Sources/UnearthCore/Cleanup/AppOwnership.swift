import Foundation

/// Whether a running app owns a folder named `owner`. Folders are named after a bundle id
/// ("com.foo.Bar", which also covers that app's helpers), an app ("discord" for Discord), or the
/// app's maker ("JetBrains" for com.jetbrains.intellij). Case never matters.
public enum AppOwnership {
    public static func owner(_ owner: String, matchesBundleID bundleID: String?, name: String?) -> Bool {
        let owner = owner.lowercased()
        if let name, name.lowercased() == owner { return true }
        guard let bundleID = bundleID?.lowercased() else { return false }
        if bundleID == owner { return true }
        if owner.contains(".") { return bundleID.hasPrefix(owner + ".") }
        // A maker's folder serves all its apps. The first part of a bundle id is only "com" or similar.
        return bundleID.split(separator: ".").dropFirst().contains { $0 == owner }
    }
}
