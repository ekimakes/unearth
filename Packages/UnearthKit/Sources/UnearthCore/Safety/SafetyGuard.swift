import Darwin
import Foundation

public enum SafetyViolation: Error, Equatable {
    case notAbsolute, outsideAllowedRoots, protectedLocation, essentialFolder, neverTouch, symlinkedParent

    public var message: String {
        switch self {
        case .notAbsolute: "That isn't a valid location."
        case .outsideAllowedRoots: "Unearth only cleans inside your home folder and on external drives."
        case .protectedLocation: "This location holds important data, so Unearth never removes it."
        case .essentialFolder: "This is an essential folder, so Unearth never removes it."
        case .neverTouch: "It's on your never-touch list."
        case .symlinkedParent: "This location changed since the scan, so Unearth left it alone."
        }
    }
}

/// The last check before anything is moved or deleted. Refuses anything it isn't sure about.
public struct SafetyGuard: Sendable {
    private let neverTouch: [String]
    private let allowedRoots: [String]
    private let essential: [String]
    private let protected: [PathPattern]
    /// The app being uninstalled and its own preferences file, the only things let through from
    /// /Applications and ~/Library/Preferences. Nil unless it's an app in Applications and a plist in Preferences.
    private let uninstalling: UninstallException?

    /// `uninstalling` is only ever passed by the Unused apps flow, for the one app being removed.
    public init(homePath home: String, neverTouch: [String], extraAllowedRoots: [String] = [],
                uninstalling: UninstallException? = nil) {
        let temp = TempFilesDetector.defaultTempDirectory()
        self.neverTouch = neverTouch
        self.uninstalling = uninstalling.flatMap { exception in
            let appFolder = (exception.appPath as NSString).deletingLastPathComponent
            let plistFolder = (exception.preferencesPlist as NSString).deletingLastPathComponent
            let isApp = exception.appPath.lowercased().hasSuffix(".app")
                && [Paths.join(home, "Applications"), "/Applications"].contains { Self.isSame(appFolder, $0) }
            let isPreferences = exception.preferencesPlist.lowercased().hasSuffix(".plist")
                && Self.isSame(plistFolder, Paths.join(home, "Library/Preferences"))
            return isApp && isPreferences ? exception : nil
        }
        allowedRoots = [home, "/Users/Shared", temp] + extraAllowedRoots
        essential = [home, "/Users/Shared", temp] + extraAllowedRoots
            + ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library", "Public", "Applications", ".Trash",
               "Library/Application Support", "Library/Caches", "Library/Containers", "Library/Group Containers",
               "Library/Preferences", "Library/Mobile Documents"].map { Paths.join(home, $0) }
        protected = ["~/Library/Keychains", "~/Library/Mail", "~/Library/Messages", "~/Library/Mobile Documents",
                     "~/Library/Preferences", "~/Pictures/*.photoslibrary"].map { PathPattern($0, homePath: home) }
    }

    public func check(_ path: String) throws(SafetyViolation) {
        if let violation = ruleViolation(for: path) { throw violation }
        // The item itself may be a link; the folders leading to it must be what the scan saw.
        let parent = (path as NSString).deletingLastPathComponent
        if let resolved = realpath(parent, nil) {
            defer { free(resolved) }
            if !Self.isSame(String(cString: resolved), parent) { throw .symlinkedParent }
        }
    }

    /// The checks that only look at the path, never at the disk, so a plan can leave out what would be refused.
    public func ruleViolation(for path: String) -> SafetyViolation? {
        let parts = path.split(separator: "/")
        guard path.hasPrefix("/"), !parts.contains(where: { $0 == "." || $0 == ".." }) else { return .notAbsolute }
        if let uninstalling, Self.isSame(path, uninstalling.appPath) || Self.isSame(path, uninstalling.preferencesPlist) {
            let neverTouched = neverTouch.contains { Paths.isSameOrInside(path, $0) || Paths.isSameOrInside($0, path) }
            return neverTouched ? .neverTouch : nil
        }
        if protected.contains(where: { Self.isSameOrInside(path, parts, $0) }) { return .protectedLocation }
        if essential.contains(where: { Self.isSame(path, $0) }) || (parts.count <= 2 && parts.first == "Volumes") {
            return .essentialFolder
        }
        if neverTouch.contains(where: { Paths.isSameOrInside(path, $0) || Paths.isSameOrInside($0, path) }) { return .neverTouch }
        let onExternalVolume = parts.count > 2 && parts.first == "Volumes"
        guard onExternalVolume || allowedRoots.contains(where: { Paths.isSameOrInside(path, $0) }) else {
            return .outsideAllowedRoots
        }
        return nil
    }

    private static func isSame(_ a: String, _ b: String) -> Bool {
        Paths.isSameOrInside(a, b) && Paths.isSameOrInside(b, a)
    }

    private static func isSameOrInside(_ path: String, _ parts: [Substring], _ pattern: PathPattern) -> Bool {
        parts.count >= pattern.components.count
            && pattern.components.indices.allSatisfy { pattern.componentMatches($0, String(parts[$0])) }
    }
}
