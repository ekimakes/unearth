import Foundation

/// The collections that are a question of where a file is, what it is and how old it is.
public struct CollectionQueries: Sendable {
    private let index: FileIndex
    private let downloads: String
    private let settings: CollectionSettings
    private let now: Date
    private let lastUsed: @Sendable (String) -> Date?

    /// `lastUsed` looks up when a file was last opened (Spotlight). `downloads` is the real path of ~/Downloads.
    public init(index: FileIndex, downloads: String, settings: CollectionSettings, now: Date,
                lastUsed: @escaping @Sendable (String) -> Date?) {
        self.index = index
        self.downloads = downloads
        self.settings = settings
        self.now = now
        self.lastUsed = lastUsed
    }

    /// Forgotten downloads, old installers, old screenshots or big old videos, largest first. Files whose
    /// contents are only in iCloud are never offered. The other collections have finders of their own.
    public func files(_ kind: CollectionKind) async -> [IndexedFile] {
        var query = SearchQuery()
        switch kind {
        case .forgottenDownloads:
            query.folder = downloads
            let cutoff = cutoff(days: settings.forgottenDownloadDays)
            return await all(query).filter { file in
                !DownloadsDetector.installerExtensions.contains(file.fileExtension)
                    && (lastUsed(file.path) ?? file.added) < cutoff
            }
        case .oldInstallers:
            query.folder = downloads
            query.extensions = DownloadsDetector.installerExtensions
            return await all(query)
        case .oldScreenshots:
            query.kinds = [.screenshot]
            let cutoff = cutoff(days: settings.screenshotDays)
            // When it was taken: filing a screenshot away later resets its date added, not its creation date.
            return await all(query).filter { ($0.created ?? $0.added) < cutoff }
        case .bigOldVideos:
            query.kinds = [.video]
            query.minBytes = settings.bigVideoBytes
            let cutoff = cutoff(days: settings.bigVideoDays)
            // The same age as Large & old files: last opened, or else last changed.
            return await all(query).filter { (lastUsed($0.path) ?? $0.modified) < cutoff }
        case .duplicates, .lookAlikes, .unusedApps:
            return []
        }
    }

    private func cutoff(days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// Every file the query's filters pass, largest first, leaving out iCloud-only files.
    private func all(_ query: SearchQuery) async -> [IndexedFile] {
        let page = 2_000
        var files: [IndexedFile] = []
        while true {
            let rows = await index.files(matching: query, sort: .size, limit: page, offset: files.count)
            files += rows
            if rows.count < page { break }
        }
        return files.filter { !$0.isCloudOnly }
    }
}
