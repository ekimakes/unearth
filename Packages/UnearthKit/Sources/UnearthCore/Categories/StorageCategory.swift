import Foundation

/// The Overview's segments, following macOS's own storage categories.
public enum StorageCategory: String, CaseIterable, Sendable, Codable {
    case apps, documents, photosVideos, iosBackups, developer, systemData, macOS, other
}

/// What "System Data" is made of.
public enum SystemDataBucket: String, CaseIterable, Sendable, Codable {
    case appCaches, logs, appData, developerTools, devCaches, aiModels, virtualMachines, deviceUpdates
    case tempFiles, swap, systemSupport, otherSystem, notIdentified
}

public struct CategoryRule: Sendable {
    public let pattern: PathPattern
    public let category: StorageCategory
    /// Set when `category` is `.systemData`.
    public let bucket: SystemDataBucket?

    public init(pattern: PathPattern, category: StorageCategory, bucket: SystemDataBucket? = nil) {
        self.pattern = pattern
        self.category = category
        self.bucket = bucket
    }
}
