import Foundation
import Synchronization
import Testing
@testable import UnearthCore

/// Folders a watcher reported, batch by batch, gathered from its callback queue.
final class ReportedFolders: Sendable {
    private let reported = Mutex<[[String]]>([])
    func add(_ batch: [String]) { reported.withLock { $0.append(batch) } }
    var batches: [[String]] { reported.withLock { $0 } }
    var all: [String] { batches.flatMap { $0 } }

    /// Waits until `condition` holds, for up to `limit`.
    func wait(upTo limit: Duration = .seconds(10), until condition: ([String]) -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if condition(all) { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return condition(all)
    }
}

struct FolderWatcherTests {
    static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @Test func reportsTheFolderThatChanged() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let sub = Self.real(try fx.dir("watched/sub"))
        let reported = ReportedFolders()
        let watcher = FolderWatcher(paths: [fx.path("watched")], latency: 0.1) { reported.add($0) }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200))
        try fx.file("watched/sub/new.txt", bytes: 10)
        #expect(try await reported.wait { $0.contains(sub) })
        #expect(reported.all.allSatisfy { !$0.hasSuffix("/") })
        // Each delivery is deduplicated; a folder can come up again in a later delivery.
        #expect(reported.batches.allSatisfy { $0.count == Set($0).count })
    }

    @Test func stopsReporting() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.dir("watched")
        let reported = ReportedFolders()
        let watcher = FolderWatcher(paths: [fx.path("watched")], latency: 0.1) { reported.add($0) }
        watcher.start()
        try await Task.sleep(for: .milliseconds(200))
        try fx.file("watched/first.txt", bytes: 10)
        #expect(try await reported.wait { !$0.isEmpty })
        watcher.stop()
        let before = reported.all.count
        try fx.file("watched/second.txt", bytes: 10)
        #expect(try await reported.wait(upTo: .seconds(1)) { $0.count > before } == false)
    }
}
