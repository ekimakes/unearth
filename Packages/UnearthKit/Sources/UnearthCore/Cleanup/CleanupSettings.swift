import Foundation

public struct CleanupSettings: Codable, Sendable, Equatable {
    public var largeFileThreshold: Int64 = 500_000_000
    public var oldFileAgeDays: Int = 182
    public var inactiveProjectDays: Int = 30
    /// Display paths the user protected. Nothing inside them, or containing them, is ever cleaned.
    public var neverTouch: [String] = []

    /// Items smaller than this are rolled into one "smaller items" row per rule.
    public static let smallItemThreshold: Int64 = 1_000_000

    public init() {}
}
