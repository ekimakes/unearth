import Foundation

/// The clean-up collections Home and the Clean up overview show as piles.
public enum CollectionKind: String, CaseIterable, Sendable, Codable {
    case duplicates, lookAlikes, forgottenDownloads, oldInstallers, oldScreenshots, bigOldVideos, unusedApps

    public var title: String {
        switch self {
        case .duplicates: "Duplicates"
        case .lookAlikes: "Look-alike photos"
        case .forgottenDownloads: "Forgotten downloads"
        case .oldInstallers: "Old installers"
        case .oldScreenshots: "Old screenshots"
        case .bigOldVideos: "Big old videos"
        case .unusedApps: "Unused apps"
        }
    }

    /// What's in the collection, counted: "12 duplicates".
    public func counted(_ count: Int) -> String {
        let name: (one: String, many: String) = switch self {
        case .duplicates: ("duplicate", "duplicates")
        case .lookAlikes: ("photo", "photos")
        case .forgottenDownloads: ("forgotten download", "forgotten downloads")
        case .oldInstallers: ("old installer", "old installers")
        case .oldScreenshots: ("old screenshot", "old screenshots")
        case .bigOldVideos: ("big old video", "big old videos")
        case .unusedApps: ("app", "apps")
        }
        return "\(count.formatted()) \(count == 1 ? name.one : name.many)"
    }

    public var explanation: Explanation {
        switch self {
        case .duplicates:
            Explanation(
                what: "Files that are exact copies of each other, byte for byte.",
                regrows: "No. These are your files.",
                safeToDelete: "Yes, for the extra copies. Unearth keeps one copy of each file and never selects them all.")
        case .lookAlikes:
            Explanation(
                what: "Photos taken moments apart, edited versions, and the same photo saved in two formats.",
                regrows: "No. These are your photos.",
                safeToDelete: "Only the ones you don't want. Nothing is selected for you, and the best shot is marked.")
        case .forgottenDownloads:
            Explanation(
                what: "Files in your Downloads folder you haven't opened in a while.",
                regrows: "No. You'd download them again if you need them.",
                safeToDelete: "Usually. Check them with Quick Look first.")
        case .oldInstallers:
            Explanation(
                what: "Installers you downloaded. Once an app is installed, its installer usually isn't needed.",
                regrows: "No. You'd download the installer again if you need it.",
                safeToDelete: "Usually. Keep one if you might reinstall and can't easily download it again.")
        case .oldScreenshots:
            Explanation(
                what: "Screenshots you took a while ago.",
                regrows: "No. These are your screenshots.",
                safeToDelete: "Usually. Most screenshots are taken for a moment and forgotten. Keep the ones you still need.")
        case .bigOldVideos:
            Explanation(
                what: "Large videos you haven't opened in months.",
                regrows: "No. These are your videos.",
                safeToDelete: "Only if you no longer need them or have a copy somewhere else.")
        case .unusedApps:
            Explanation(
                what: "Apps you haven't opened in a while, with the settings and caches they keep in your home folder.",
                regrows: "No. If you need an app again, you can download it, and its settings start fresh.",
                safeToDelete: "Yes, if you don't use the app anymore. Everything goes to the Trash, so you can put it back.")
        }
    }

    /// One file of the collection, ready for the cleanup engine. Nothing in a collection is selected for the user.
    public func item(for file: IndexedFile, onDiskBytes: Int64) -> CleanupItem {
        CleanupItem(
            ruleID: "collection-\(rawValue)", section: .manual, group: title, title: file.name, subtitle: nil,
            paths: [file.path], bytes: onDiskBytes, safety: .review, action: .trash, explanation: explanation, owner: nil,
            blockedReason: nil)
    }
}

/// The thresholds behind the collections. Settings can change them.
public struct CollectionSettings: Codable, Sendable, Equatable {
    public var forgottenDownloadDays = 90
    public var screenshotDays = 30
    public var bigVideoBytes: Int64 = 500_000_000
    public var bigVideoDays = 182
    public var unusedAppDays = 90
    public var duplicateMinBytes: Int64 = 1_000_000

    public init() {}
}
