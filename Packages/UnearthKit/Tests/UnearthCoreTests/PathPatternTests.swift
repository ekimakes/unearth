import Foundation
import Testing
@testable import UnearthCore

struct PathPatternTests {
    @Test func expandsHome() {
        #expect(PathPattern("~/Library/Caches/*", homePath: "/Users/u").matches("/Users/u/Library/Caches/com.x"))
    }

    @Test func starIsOneComponent() {
        #expect(!PathPattern("~/Library/Caches/*", homePath: "/Users/u").matches("/Users/u/Library/Caches/a/b"))
        #expect(!PathPattern("~/Library/Caches/*", homePath: "/Users/u").matches("/Users/u/Library/Caches"))
    }

    @Test func globsWithinComponent() {
        let pattern = PathPattern("~/Pictures/*.photoslibrary", homePath: "/Users/u")
        #expect(pattern.matches("/Users/u/Pictures/Photos Library.photoslibrary"))
        #expect(!pattern.matches("/Users/u/Pictures/Photos Library"))
    }

    @Test func dotFoldersNeedAnExplicitDot() {
        #expect(!PathPattern("~/*", homePath: "/Users/u").matches("/Users/u/.npm"))
        #expect(PathPattern("~/.*", homePath: "/Users/u").matches("/Users/u/.npm"))
    }

    @Test func ignoresCaseLikeAPFS() {
        #expect(PathPattern("~/library/caches", homePath: "/Users/u").matches("/Users/u/Library/Caches"))
    }

    @Test func rootPatternMatchesOnlyRoot() {
        #expect(PathPattern("/", homePath: "/Users/u").matches("/"))
        #expect(!PathPattern("/", homePath: "/Users/u").matches("/Users"))
    }

    @Test func nodesMatchingWalksTree() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        for name in ["com.a", "com.b", "org.c"] { try fx.file("Users/u/Library/Caches/\(name)/blob", bytes: 10) }
        try fx.file("Users/u/Library/Logs/x/log", bytes: 10)
        let tree = try await DiskScanner().scan(ScanOptions(rootPath: fx.root, displayRoot: "/"))
        let matches = tree.nodes(matching: PathPattern("~/Library/Caches/*", homePath: "/Users/u"))
        #expect(Set(matches.map { tree.path(of: $0) }) == [
            "/Users/u/Library/Caches/com.a", "/Users/u/Library/Caches/com.b", "/Users/u/Library/Caches/org.c",
        ])
    }
}
