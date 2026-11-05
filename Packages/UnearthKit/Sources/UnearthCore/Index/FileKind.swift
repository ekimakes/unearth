import Foundation

/// What a file is, the way the Library groups files.
public enum FileKind: String, Codable, Sendable, CaseIterable {
    case image, screenshot, video, document, audio, archive, app, other
}

public enum FileClassifier {
    private static let images: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp", "avif", "svg",
        "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2",
    ]
    private static let videos: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm", "3gp", "mts", "mpg", "mpeg", "wmv"]
    private static let audio: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus", "caf"]
    private static let documents: Set<String> = [
        "pdf", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "csv", "ppt", "pptx", "txt", "md", "rtf", "rtfd",
        "epub", "odt", "ods", "odp", "json", "xml", "html",
    ]
    private static let archives: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z", "dmg", "pkg", "mpkg", "xip", "iso"]
    private static let screenshotPrefixes = ["screenshot ", "screen shot ", "cleanshot "]

    /// `isScreenshot` is the flag macOS sets on screenshots; the name catches older ones and other tools.
    /// Screen recordings stay videos.
    public static func kind(forName name: String, isScreenshot: Bool) -> FileKind {
        let ext = fileExtension(name).split(separator: ".").last.map(String.init) ?? ""
        if ext == "app" { return .app }
        if images.contains(ext) { return isScreenshot || isScreenshotName(name) ? .screenshot : .image }
        if videos.contains(ext) { return .video }
        if audio.contains(ext) { return .audio }
        if documents.contains(ext) { return .document }
        if archives.contains(ext) { return .archive }
        return .other
    }

    public static func isScreenshotName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return screenshotPrefixes.contains { lower.hasPrefix($0) }
    }

    /// Lowercased, "" when there's none; "tar.gz" and the like stay whole.
    public static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        let last = name[name.index(after: dot)...].lowercased()
        let stem = name[..<dot].lowercased()
        return stem.hasSuffix(".tar") && stem.count > 4 ? "tar." + last : last
    }
}
