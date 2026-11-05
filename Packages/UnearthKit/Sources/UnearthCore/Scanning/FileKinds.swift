import Foundation

/// Marker files that identify a folder as a software project.
public struct ProjectMarkers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let packageJSON = ProjectMarkers(rawValue: 1 << 0)
    public static let cargoToml = ProjectMarkers(rawValue: 1 << 1)
    public static let podfile = ProjectMarkers(rawValue: 1 << 2)
    public static let pythonProject = ProjectMarkers(rawValue: 1 << 3)
    public static let gradle = ProjectMarkers(rawValue: 1 << 4)
    public static let swiftPackage = ProjectMarkers(rawValue: 1 << 5)
    public static let xcodeProject = ProjectMarkers(rawValue: 1 << 6)
    public static let gitRepository = ProjectMarkers(rawValue: 1 << 7)
    public static let unityProject = ProjectMarkers(rawValue: 1 << 8)
}

public enum FileKinds {
    private static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp",
        "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2",
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "3gp", "mts",
    ]

    /// Folders macOS shows as a single file: apps, libraries, document packages. Taking one file out of
    /// one breaks the whole thing.
    public static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "prefpane", "saver",
        "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "photoboothlibrary", "lrlibrary", "lrdata",
        "fcpbundle", "imovielibrary", "theater", "tvlibrary", "musiclibrary", "logicx", "band",
        "key", "pages", "numbers", "rtfd", "scriv", "xcodeproj", "xcworkspace", "playground", "xcarchive", "docarchive",
        "sparsebundle", "vmwarevm", "pvm", "utm", "abbu",
    ]

    /// What cameras and phones save: the only images that count as photos for look-alikes. PNG, GIF and
    /// the like are mostly graphics, and graphics downloaded together aren't a burst.
    public static let photoExtensions: Set<String> = [
        "heic", "heif", "jpg", "jpeg", "dng", "raw", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf",
    ]

    public static func isPackage(name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return packageExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// Whether `path` lies inside a package. The package itself doesn't count.
    public static func isInsidePackage(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { isPackage(name: String($0)) }
    }

    /// Images and videos, by extension.
    public static func isMedia(name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        guard ext.count <= 4 else { return false }
        return mediaExtensions.contains(ext.lowercased())
    }

    public static func marker(forEntryNamed name: String) -> ProjectMarkers {
        switch name {
        case "package.json": return .packageJSON
        case "Cargo.toml": return .cargoToml
        case "Podfile": return .podfile
        case "pyproject.toml", "requirements.txt", "setup.py": return .pythonProject
        case "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts": return .gradle
        case "Package.swift": return .swiftPackage
        case ".git": return .gitRepository
        case "ProjectSettings": return .unityProject
        default: return name.hasSuffix(".xcodeproj") ? .xcodeProject : []
        }
    }
}
