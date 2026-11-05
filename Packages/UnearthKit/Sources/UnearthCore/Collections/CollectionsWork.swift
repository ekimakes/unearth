import Foundation

/// A cheap summary of the rows a collection looks at: if it hasn't changed, neither has the collection.
public struct IndexFingerprint: Equatable, Sendable {
    public let count: Int
    public let maxID: Int64
    /// The newest modification date among the rows.
    public let latest: Double
    /// How many of them have a feature print (look-alikes only).
    public let prints: Int

    public init(count: Int, maxID: Int64, latest: Double, prints: Int) {
        self.count = count
        self.maxID = maxID
        self.latest = latest
        self.prints = prints
    }
}

/// What the collections were last looked at with.
public struct CollectionsState: Equatable, Sendable {
    /// The disk scan the apps were listed after.
    public var scan: UUID?
    public var duplicates: IndexFingerprint
    public var photos: IndexFingerprint
    public var settings: CollectionSettings

    public init(scan: UUID?, duplicates: IndexFingerprint, photos: IndexFingerprint, settings: CollectionSettings) {
        self.scan = scan
        self.duplicates = duplicates
        self.photos = photos
        self.settings = settings
    }
}

/// The heavy parts of a look that have to be done again. The cheap lists (downloads, installers, screenshots,
/// videos) are always looked at; apps only after a new scan, duplicates and look-alikes only when their rows changed.
public struct CollectionsWork: Equatable, Sendable {
    public var apps: Bool
    public var duplicates: Bool
    public var lookAlikes: Bool

    public init(apps: Bool, duplicates: Bool, lookAlikes: Bool) {
        self.apps = apps
        self.duplicates = duplicates
        self.lookAlikes = lookAlikes
    }

    public static func needed(since previous: CollectionsState?, now current: CollectionsState) -> CollectionsWork {
        guard let previous else { return CollectionsWork(apps: true, duplicates: true, lookAlikes: true) }
        return CollectionsWork(
            apps: previous.scan != current.scan || previous.settings.unusedAppDays != current.settings.unusedAppDays,
            duplicates: previous.duplicates != current.duplicates
                || previous.settings.duplicateMinBytes != current.settings.duplicateMinBytes,
            lookAlikes: previous.photos != current.photos)
    }
}

extension FileIndex {
    /// The files Duplicates looks at: on this Mac and at least `minBytes`. Their prints don't matter to it.
    public func duplicatesFingerprint(minBytes: Int64) -> IndexFingerprint {
        fingerprint(where: "cloud = 0 AND bytes >= ?1", [.integer(minBytes)], countingPrints: false)
    }

    /// The photos Look-alike photos looks at, and their prints.
    public func lookAlikesFingerprint() -> IndexFingerprint {
        let photos = FileKinds.photoExtensions.sorted().map { "'\($0)'" }.joined(separator: ", ")
        return fingerprint(where: "kind = 'image' AND cloud = 0 AND ext IN (\(photos))", [], countingPrints: true)
    }

    private func fingerprint(where condition: String, _ values: [SQLValue], countingPrints: Bool) -> IndexFingerprint {
        let prints = countingPrints ? "coalesce(sum(print IS NOT NULL), 0)" : "0"
        let rows = try? statement("""
            SELECT count(*), coalesce(max(id), 0), coalesce(max(modified), 0), \(prints) FROM files WHERE \(condition)
            """).rows(values) {
                IndexFingerprint(count: Int($0.int64(0)), maxID: $0.int64(1), latest: $0.double(2), prints: Int($0.int64(3)))
            }
        return rows?.first ?? IndexFingerprint(count: 0, maxID: 0, latest: 0, prints: 0)
    }
}
