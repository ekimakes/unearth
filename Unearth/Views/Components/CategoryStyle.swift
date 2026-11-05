import SwiftUI
import UnearthCore

/// Names, colors and one-line explanations for storage categories and System Data buckets.
enum CategoryStyle {
    /// Order of the storage bar and its legend.
    static let order: [StorageCategory] = [.apps, .documents, .photosVideos, .iosBackups, .developer, .systemData, .macOS, .other]

    static func color(_ category: StorageCategory) -> Color { category.color }

    static func name(_ category: StorageCategory) -> String {
        switch category {
        case .apps: "Apps"
        case .documents: "Documents"
        case .photosVideos: "Photos & Videos"
        case .iosBackups: "iPhone & iPad Backups"
        case .developer: "Developer"
        case .systemData: "System Data"
        case .macOS: "macOS"
        case .other: "Other"
        }
    }

    static func name(_ bucket: SystemDataBucket) -> String {
        switch bucket {
        case .appCaches: "App caches"
        case .logs: "Logs"
        case .appData: "App data"
        case .developerTools: "Developer tools"
        case .devCaches: "Developer caches"
        case .aiModels: "AI models"
        case .virtualMachines: "Virtual machines & containers"
        case .deviceUpdates: "iPhone & iPad updates"
        case .tempFiles: "Temporary files"
        case .swap: "Swap & sleep image"
        case .systemSupport: "macOS startup & recovery files"
        case .otherSystem: "Other system files"
        case .notIdentified: "Not identified"
        }
    }

    static func explanation(_ bucket: SystemDataBucket) -> String {
        switch bucket {
        case .appCaches: "Temporary files apps keep so they load faster."
        case .logs: "Records apps and macOS keep about what they did."
        case .appData: "Settings, databases and saved state that apps store for you."
        case .developerTools: "Simulator runtimes, command-line tools and other developer software."
        case .devCaches: "Code libraries that package managers downloaded."
        case .aiModels: "AI models downloaded to run on this Mac."
        case .virtualMachines: "Disk images for Docker, virtual machines and containers."
        case .deviceUpdates: "Software update files for iPhone and iPad."
        case .tempFiles: "Files apps create while they work."
        case .swap: "Space macOS uses as extra memory when apps need more than your Mac has."
        case .systemSupport: "Files macOS needs to start up, update and recover."
        case .otherSystem: "Other files macOS and apps keep outside your home folder."
        case .notIdentified: "Space macOS keeps for itself or that Unearth isn't allowed to read: other users' files, system databases and Time Machine snapshots."
        }
    }
}

extension SidebarItem {
    var title: String {
        switch self {
        case .home: "Home"
        case .recents: "Recents"
        case .kind(let kind): kind.title
        case .downloadedFrom: "Downloaded from"
        case .source(let source): "From \(source)"
        case .storage: "Storage"
        case .diskMap: "Disk Map"
        case .systemData: "System Data"
        case .junk: "Caches & junk"
        case .developer: "Developer & AI"
        case .largeFiles: "Large & old files"
        case .cleanUp: "Clean up"
        case .collection(let kind): kind.title
        case .place(let path): Self.isHomeFolder(path) ? "Home folder" : FileManager.default.displayName(atPath: path)
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .recents: "clock"
        case .kind(let kind): kind.symbol
        case .downloadedFrom, .source: "tray.and.arrow.down"
        case .storage: "internaldrive"
        case .diskMap: "chart.pie"
        case .systemData: "gearshape.2"
        case .junk: "bubbles.and.sparkles"
        case .developer: "hammer"
        case .largeFiles: "archivebox"
        case .cleanUp: "sparkles"
        case .collection(let kind): kind.symbol
        case .place(let path):
            Self.isHomeFolder(path) ? "person.crop.square" : Self.placeSymbols[(path as NSString).lastPathComponent] ?? "folder"
        }
    }

    /// Home folders live directly in /Users (also on the demo disk).
    private static func isHomeFolder(_ path: String) -> Bool {
        (path as NSString).deletingLastPathComponent.hasSuffix("/Users")
    }

    private static let placeSymbols = [
        "Desktop": "menubar.dock.rectangle", "Documents": "doc", "Downloads": "arrow.down.circle",
        "Pictures": "photo", "Movies": "film", "Music": "music.note", "Applications": "square.grid.3x3",
    ]

    /// The screen behind a cleanup section.
    static func screen(for section: CleanupSection) -> SidebarItem {
        switch section {
        case .junk: .junk
        case .developer: .developer
        case .largeFiles: .largeFiles
        case .manual: .storage
        }
    }
}

extension FileKind {
    var symbol: String {
        switch self {
        case .image: "photo"
        case .screenshot: "camera.viewfinder"
        case .video: "film"
        case .document: "doc.text"
        case .audio: "music.note"
        case .archive: "doc.zipper"
        case .app: "app"
        case .other: "doc"
        }
    }
}

extension CollectionKind {
    var symbol: String {
        switch self {
        case .duplicates: "plus.square.on.square"
        case .lookAlikes: "photo.on.rectangle.angled"
        case .forgottenDownloads: "arrow.down.circle"
        case .oldInstallers: "shippingbox"
        case .oldScreenshots: "camera.viewfinder"
        case .bigOldVideos: "film.stack"
        case .unusedApps: "app.dashed"
        }
    }

    /// The line under a pile's size: what's in it, in plain words.
    func detail(count: Int, settings: CollectionSettings) -> String {
        func files(_ one: String, _ many: String) -> String { count == 1 ? "1 \(one)" : "\(count.formatted()) \(many)" }
        switch self {
        case .duplicates: return files("extra copy", "extra copies")
        case .lookAlikes: return files("group of similar photos", "groups of similar photos")
        case .forgottenDownloads: return files("file", "files") + ", not opened in \(Self.age(settings.forgottenDownloadDays))"
        case .oldInstallers: return files("installer", "installers") + " in Downloads"
        case .oldScreenshots: return files("screenshot", "screenshots") + " older than \(Self.age(settings.screenshotDays))"
        case .bigOldVideos: return files("video", "videos") + ", not opened in \(Self.age(settings.bigVideoDays))"
        case .unusedApps: return files("app", "apps") + ", not opened in \(Self.age(settings.unusedAppDays))"
        }
    }

    /// "a month", "3 months", "a year", "10 days".
    static func age(_ days: Int) -> String {
        if days <= 0 { return "a while" }
        if days >= 365, days % 365 < 15 { return days < 730 ? "a year" : "\(days / 365) years" }
        if days >= 28 {
            let months = Int((Double(days) / 30.44).rounded())
            return months == 1 ? "a month" : "\(months) months"
        }
        if days == 7 { return "a week" }
        return days == 1 ? "a day" : "\(days) days"
    }
}
