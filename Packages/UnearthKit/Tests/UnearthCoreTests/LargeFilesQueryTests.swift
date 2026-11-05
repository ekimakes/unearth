import Foundation
import Testing
@testable import UnearthCore

struct LargeFilesQueryTests {
    static let old = Date().addingTimeInterval(-400 * 86_400)

    static func tree() async throws -> (HomeFixture, ScanTree) {
        let home = try HomeFixture()
        try home.file("/Users/u/Movies/old.mov", bytes: 3_000_000, modified: old)
        try home.file("/Users/u/Movies/new.mov", bytes: 3_000_000, modified: Date().addingTimeInterval(-2 * 86_400))
        try home.file("/Users/u/Documents/small.pdf", bytes: 500_000, modified: old)
        try home.file("/Users/u/Projects/keep/big.bin", bytes: 3_000_000, modified: old)
        try home.file("/Library/Big/system.bin", bytes: 3_000_000, modified: old)
        return (home, try await home.scan(bigFileFloor: 100_000))
    }

    static func query(days: Int? = 182, lastUsed: @escaping @Sendable (String) -> Date? = { _ in nil }) -> LargeFilesQuery {
        LargeFilesQuery(minimumBytes: 1_000_000, notOpenedForDays: days, now: Date(), homePath: HomeFixture.home, lastUsed: lastUsed)
    }

    static func safety(neverTouch: [String] = []) -> SafetyGuard {
        SafetyGuard(homePath: HomeFixture.home, neverTouch: neverTouch)
    }

    /// Scans a home holding old 2 MB files at `paths`, returning the titles the query offers.
    static func offered(_ paths: [String]) async throws -> Set<String> {
        let home = try HomeFixture()
        defer { home.remove() }
        for path in paths { try home.file(path, bytes: 2_000_000, modified: old) }
        let tree = try await home.scan(bigFileFloor: 100_000)
        return Set(query().items(from: tree, safetyGuard: safety()).map(\.title))
    }

    @Test func filtersBySizeAndAge() async throws {
        let (home, tree) = try await Self.tree()
        defer { home.remove() }
        let items = Self.query().items(from: tree, safetyGuard: Self.safety())
        #expect(Set(items.map(\.title)) == ["old.mov", "big.bin"])
        #expect(items.allSatisfy { $0.section == .largeFiles && $0.safety == .review && $0.action == .trash })
        #expect(items.first { $0.title == "old.mov" }?.paths == ["/Users/u/Movies/old.mov"])
        #expect(Set(Self.query(days: nil).items(from: tree, safetyGuard: Self.safety()).map(\.title)) == ["old.mov", "new.mov", "big.bin"])
    }

    @Test func fallsBackToModificationDate() async throws {
        let (home, tree) = try await Self.tree()
        defer { home.remove() }
        let openedToday = Self.query { $0.hasSuffix("old.mov") ? Date() : nil }.items(from: tree, safetyGuard: Self.safety())
        #expect(Set(openedToday.map(\.title)) == ["big.bin"])
        let subtitle = Self.query().items(from: tree, safetyGuard: Self.safety()).first { $0.title == "old.mov" }?.subtitle
        #expect(subtitle?.hasPrefix("Modified ") == true)
        let opened = Self.query { _ in Self.old }.items(from: tree, safetyGuard: Self.safety()).first { $0.title == "old.mov" }?.subtitle
        #expect(opened?.hasPrefix("Last opened ") == true)
    }

    @Test func excludesNeverTouch() async throws {
        let (home, tree) = try await Self.tree()
        defer { home.remove() }
        let items = Self.query().items(from: tree, safetyGuard: Self.safety(neverTouch: ["/Users/u/Projects/keep"]))
        #expect(items.map(\.title) == ["old.mov"])
    }

    @Test func excludesFilesOutsideAllowedRoots() async throws {
        let (home, tree) = try await Self.tree()
        defer { home.remove() }
        #expect(!Self.query(days: nil).items(from: tree, safetyGuard: Self.safety()).contains { $0.title == "system.bin" })
    }

    /// Removing one file from inside a library, an app or a document package breaks the whole thing.
    @Test func skipsPiecesOfPackagesAndLibraries() async throws {
        let offered = try await Self.offered([
            "/Users/u/Desktop/Old.photoslibrary/originals/A/IMG_0001.mov",
            "/Users/u/Movies/Edit.fcpbundle/Clip/Render Files/render.mov",
            "/Users/u/Applications/Tool.app/Contents/Resources/model.bin",
            "/Users/u/Music/Song.logicx/Media/Audio Files/take.wav",
            "/Users/u/Documents/Talk.key/Data/movie.mov",
            "/Users/u/Movies/keep.mov",
        ])
        #expect(offered == ["keep.mov"])
    }

    /// Deleting a virtual machine's disk loses everything inside; those are cleaned from the app that made them.
    @Test func skipsVirtualMachineDisks() async throws {
        let offered = try await Self.offered([
            "/Users/u/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img",
            "/Users/u/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
            "/Users/u/VMs/windows.vmdk",
            "/Users/u/VMs/linux.qcow2",
            "/Users/u/Downloads/ubuntu.iso",
        ])
        #expect(offered == ["ubuntu.iso"])
    }

    /// Files Unearth would refuse to move anyway (Mail, iCloud Drive, the Photos library) aren't offered.
    @Test func skipsProtectedLocations() async throws {
        let offered = try await Self.offered([
            "/Users/u/Library/Mail/V10/Account/INBOX.mbox/Attachments/big.zip",
            "/Users/u/Library/Mobile Documents/com~apple~CloudDocs/big.zip",
            "/Users/u/Downloads/setup.zip",
        ])
        #expect(offered == ["setup.zip"])
    }
}
