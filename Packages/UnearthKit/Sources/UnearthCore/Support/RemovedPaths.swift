import Foundation

/// What left the disk. A folder counts with everything that was in it, and names compare the way default APFS
/// volumes compare them, as in `Paths.isSameOrInside`.
public struct RemovedPaths: Sendable, Equatable {
    /// Each path as it was given, by the form it compares in.
    private var removed: [String: String] = [:]

    public init() {}

    public var paths: [String] { Array(removed.values) }

    public mutating func insert(contentsOf paths: some Sequence<String>) {
        for path in paths { removed[Self.key(path)] = path }
    }

    /// Stops counting these: they're back on disk.
    public mutating func forget(_ paths: some Sequence<String>) {
        for path in paths { removed[Self.key(path)] = nil }
    }

    /// Whether this path, or a folder it's in, left.
    public func covers(_ path: String) -> Bool {
        guard !removed.isEmpty else { return false }
        var key = ""
        for part in Paths.comparableComponents(path) {
            key += "/" + part
            if removed[key] != nil { return true }
        }
        return false
    }

    private static func key(_ path: String) -> String {
        Paths.comparableComponents(path).map { "/" + $0 }.joined()
    }
}
