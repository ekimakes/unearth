import Foundation

public enum Paths {
    public static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    /// Component-wise containment. Matches the way default APFS volumes compare names:
    /// case-insensitive and Unicode-normalization-insensitive, so it errs toward "inside".
    public static func isSameOrInside(_ path: String, _ ancestor: String) -> Bool {
        let pathParts = comparableComponents(path)
        let ancestorParts = comparableComponents(ancestor)
        guard ancestorParts.count <= pathParts.count else { return false }
        return zip(pathParts, ancestorParts).allSatisfy { $0 == $1 }
    }

    static func comparableComponents(_ path: String) -> [String] {
        path.split(separator: "/").map { String($0).precomposedStringWithCanonicalMapping.lowercased() }
    }
}
