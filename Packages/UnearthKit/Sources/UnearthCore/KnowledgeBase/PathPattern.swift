import Darwin
import Foundation

/// A path with per-component wildcards: `~/Library/Caches/*`, `~/Pictures/*.photoslibrary`.
/// `*` never crosses a `/`, a leading `.` must be matched explicitly, and case is ignored (like APFS).
public struct PathPattern: Sendable, Hashable {
    public let components: [String]
    private let matchers: [Matcher]

    private enum Matcher: Sendable, Hashable {
        case literal(String)   // folded for comparison
        case glob(String)
    }

    public init(_ pattern: String, homePath: String) {
        var expanded = pattern
        if pattern == "~" {
            expanded = homePath
        } else if pattern.hasPrefix("~/") {
            expanded = homePath + pattern.dropFirst()
        }
        components = expanded.split(separator: "/").map(String.init)
        matchers = components.map { component in
            component.contains(where: { "*?[".contains($0) })
                ? .glob(component)
                : .literal(Self.fold(component))
        }
    }

    public func matches(_ displayPath: String) -> Bool {
        let parts = displayPath.split(separator: "/")
        guard parts.count == components.count else { return false }
        return parts.indices.allSatisfy { componentMatches($0, String(parts[$0])) }
    }

    /// Whether path component `index` of this pattern matches a file or folder name.
    public func componentMatches(_ index: Int, _ name: String) -> Bool {
        switch matchers[index] {
        case .literal(let folded):
            return Self.fold(name) == folded
        case .glob(let glob):
            return fnmatch(glob, name, FNM_PERIOD | FNM_CASEFOLD) == 0
        }
    }

    private static func fold(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}

extension ScanTree {
    /// Every scanned folder whose display path matches `pattern`, walking only matching branches.
    public func nodes(matching pattern: PathPattern) -> [NodeID] {
        let rootParts = displayRoot.split(separator: "/").map(String.init)
        guard pattern.components.count >= rootParts.count,
              rootParts.indices.allSatisfy({ pattern.componentMatches($0, rootParts[$0]) }) else { return [] }
        var current = [rootID]
        for index in rootParts.count..<pattern.components.count {
            current = current.flatMap { id in
                node(id).children.filter { pattern.componentMatches(index, node($0).name) }
            }
            if current.isEmpty { break }
        }
        return current
    }
}
