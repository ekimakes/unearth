import Foundation
import Testing
@testable import UnearthCore

/// The Disk Map outlives scans, and node ids only mean something inside one scan.
struct DiskMapStateTests {
    static let taxes = "/Users/u/Documents/Taxes"
    static let trip = "/Users/u/Movies/Trip"

    /// Two scans of one home; between them a folder goes away and others appear, so ids get reassigned.
    static func scans() async throws -> (HomeFixture, ScanTree, ScanTree) {
        let home = try HomeFixture()
        try home.file(trip + "/clip.mov", bytes: 300_000)
        try home.file(taxes + "/2025.pdf", bytes: 200_000)
        try home.file("/Users/u/Music/song.m4a", bytes: 100_000)
        let first = try await home.scan()
        try FileManager.default.removeItem(atPath: home.fx.path("data" + trip))
        try home.file("/Users/u/Archive/a/b/c/old.zip", bytes: 50_000)
        try home.file("/Users/u/Documents/Taxes/2024/receipts.pdf", bytes: 70_000)
        let second = try await home.scan()
        return (home, first, second)
    }

    @Test func focusFollowsTheFolderIntoTheNextScan() async throws {
        let (home, first, second) = try await Self.scans()
        defer { home.remove() }
        var state = DiskMapState()
        state.focus(on: try #require(first.nodeID(forPath: Self.taxes)), in: first)
        #expect(state.focus(in: second) == second.nodeID(forPath: Self.taxes))
    }

    @Test func focusFallsBackToTheTopWhenTheFolderIsGone() async throws {
        let (home, first, second) = try await Self.scans()
        defer { home.remove() }
        var state = DiskMapState()
        state.focus(on: try #require(first.nodeID(forPath: Self.trip)), in: first)
        #expect(state.focus(in: first) == first.nodeID(forPath: Self.trip))
        #expect(state.focus(in: second) == second.rootID)
    }

    @Test func trashUsesThePickedFolderNotItsOldNodeID() async throws {
        let (home, first, second) = try await Self.scans()
        defer { home.remove() }
        var state = DiskMapState()
        state.askToTrash(try #require(first.nodeID(forPath: Self.taxes)), in: first)
        let item = try #require(state.trashItem(in: second))
        #expect(item.paths == [Self.taxes])
        #expect(item.bytes == second.node(try #require(second.nodeID(forPath: Self.taxes))).totalBytes)
        #expect(item.title == "Taxes")
        #expect(item.section == .manual && item.safety == .careful && item.action == .trash)
        state.cancelTrash()
        #expect(state.trashItem(in: second) == nil)
    }

    @Test func trashOfAFolderThatWentAwayOffersNothing() async throws {
        let (home, first, second) = try await Self.scans()
        defer { home.remove() }
        var state = DiskMapState()
        state.askToTrash(try #require(first.nodeID(forPath: Self.trip)), in: first)
        #expect(state.trashPath == Self.trip)
        #expect(state.trashItem(in: second) == nil)
    }

    @Test func everyScanHasItsOwnID() async throws {
        let (home, first, second) = try await Self.scans()
        defer { home.remove() }
        #expect(first.id != second.id)
    }
}
