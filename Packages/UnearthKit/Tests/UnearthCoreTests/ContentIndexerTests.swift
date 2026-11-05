import Foundation
import Synchronization
import Testing
@testable import UnearthCore

final class FakeRecognizer: ContentRecognizing {
    struct Unreadable: Error {}
    private let calls = Mutex<[String]>([])
    /// How many reads are running right now, and the most there ever were.
    private let running = Mutex((now: 0, most: 0))
    private let failing: Set<String>
    private let delay: Duration
    /// Runs as each read starts, with how many have started.
    private let onCall: @Sendable (Int) -> Void

    /// Keeps reading even when cancelled, like a Vision request already under way.
    private let ignoresCancellation: Bool

    init(failing: Set<String> = [], delay: Duration = .zero, ignoresCancellation: Bool = false,
         onCall: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.failing = failing
        self.delay = delay
        self.ignoresCancellation = ignoresCancellation
        self.onCall = onCall
    }

    var paths: [String] { calls.withLock { $0 } }
    var mostAtOnce: Int { running.withLock { $0.most } }

    func recognize(imageAt path: String) async throws -> RecognizedContent {
        onCall(calls.withLock { $0.append(path); return $0.count })
        running.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
        defer { running.withLock { $0.now -= 1 } }
        if delay > .zero {
            if ignoresCancellation {
                let seconds = Double(delay.components.attoseconds) / 1e18 + Double(delay.components.seconds)
                await withCheckedContinuation { done in DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.resume() } }
            } else {
                try await Task.sleep(for: delay)
            }
        }
        if failing.contains((path as NSString).lastPathComponent) { throw Unreadable() }
        return RecognizedContent(text: "TEXT IN \((path as NSString).lastPathComponent)", labels: ["tree"])
    }
}

final class FakePower: PowerStateProviding {
    private let state: Mutex<Bool>
    init(paused: Bool) { state = Mutex(paused) }
    var shouldPause: Bool { state.withLock { $0 } }
    func set(paused: Bool) { state.withLock { $0 = paused } }
}

/// Makes a four-byte print for every image it's asked about.
final class FakePrinter: FeaturePrinting {
    private let calls = Mutex<[String]>([])
    var paths: [String] { calls.withLock { $0 } }

    func featurePrint(ofImageAt path: String) async throws -> Data? {
        calls.withLock { $0.append(path) }
        return Data([1, 2, 3, 4])
    }
}

struct ContentIndexerTests {
    static func index(_ records: [IndexedFileRecord]) async throws -> FileIndex {
        let index = try FileIndex.inMemory()
        try await index.upsert(records, generation: await index.beginPass())
        return index
    }

    static let images = [
        FileIndexTests.record("/u/a.jpg", kind: .image, bytes: 50_000, added: 1),
        FileIndexTests.record("/u/b.png", kind: .screenshot, bytes: 50_000, added: 3),
        FileIndexTests.record("/u/c.jpg", kind: .image, bytes: 50_000, added: 2), FileIndexTests.record("/u/notes.pdf"),
    ]

    @Test func recognizesAllPendingImagesNewestFirst() async throws {
        let index = try await Self.index(Self.images)
        let recognizer = FakeRecognizer()
        await ContentIndexer(index: index, recognizer: recognizer, power: FakePower(paused: false)).run(batchSize: 2)
        #expect(recognizer.paths == ["/u/b.png", "/u/c.jpg", "/u/a.jpg"])
        #expect(await index.recognitionCounts() == (done: 3, pending: 0))
        var query = SearchQuery()
        query.text = "text in c"
        #expect(await index.search(query, limit: 5).first?.file.name == "c.jpg")
    }

    @Test func failuresAreMarkedAndSkipped() async throws {
        let index = try await Self.index(Self.images)
        let recognizer = FakeRecognizer(failing: ["c.jpg"])
        await ContentIndexer(index: index, recognizer: recognizer, power: FakePower(paused: false)).run()
        #expect(recognizer.paths.count == 3)
        #expect(await index.recognitionCounts() == (done: 2, pending: 0))
    }

    @Test func skipsCloudOnlyAndHugeImages() async throws {
        let index = try await Self.index([
            FileIndexTests.record("/u/cloud.jpg", kind: .image, bytes: 50_000, cloud: true),
            FileIndexTests.record("/u/huge.png", kind: .image, bytes: 250_000_000),
            FileIndexTests.record("/u/ok.jpg", kind: .image, bytes: 50_000),
        ])
        let recognizer = FakeRecognizer()
        await ContentIndexer(index: index, recognizer: recognizer, power: FakePower(paused: false)).run()
        #expect(recognizer.paths == ["/u/ok.jpg"])
    }

    @Test func pausesWhilePowerSaysPause() async throws {
        let index = try await Self.index(Self.images)
        let recognizer = FakeRecognizer()
        let power = FakePower(paused: true)
        let indexer = ContentIndexer(index: index, recognizer: recognizer, power: power, pauseInterval: .milliseconds(10))
        let running = Task { await indexer.run() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(recognizer.paths.isEmpty)
        power.set(paused: false)
        await running.value
        #expect(recognizer.paths.count == 3)
    }

    @Test func readsSeveralImagesAtOnce() async throws {
        let many = (0..<12).map { FileIndexTests.record("/u/\($0).jpg", kind: .image, bytes: 50_000, added: Double($0)) }
        let index = try await Self.index(many)
        let recognizer = FakeRecognizer(delay: .milliseconds(30))
        await ContentIndexer(index: index, recognizer: recognizer, power: FakePower(paused: false)).run(batchSize: 6, concurrency: 3)
        #expect(recognizer.paths.count == 12)
        #expect(recognizer.mostAtOnce == 3)
        #expect(await index.recognitionCounts() == (done: 12, pending: 0))
    }

    /// A pause in the middle of a batch must not drop the images that hadn't started yet.
    @Test func resumesTheRestOfABatchAfterAPause() async throws {
        let index = try await Self.index((0..<4).map {
            FileIndexTests.record("/u/\($0).jpg", kind: .image, bytes: 50_000, added: Double($0))
        })
        let power = FakePower(paused: false)
        let recognizer = FakeRecognizer { started in if started == 1 { power.set(paused: true) } }
        let resume = Task {
            try await Task.sleep(for: .milliseconds(150))
            power.set(paused: false)
        }
        await ContentIndexer(index: index, recognizer: recognizer, power: power, pauseInterval: .milliseconds(10)).run()
        _ = try await resume.value
        #expect(recognizer.paths.count == 4)
        #expect(await index.recognitionCounts() == (done: 4, pending: 0))
    }

    /// Reads that finish after the run was cancelled (Forget Everything, a new set of folders) aren't saved.
    @Test func aCancelledRunSavesNothingMore() async throws {
        let index = try await Self.index((0..<6).map {
            FileIndexTests.record("/u/\($0).jpg", kind: .image, bytes: 50_000, added: Double($0))
        })
        let recognizer = FakeRecognizer(delay: .milliseconds(80), ignoresCancellation: true)
        let indexer = ContentIndexer(index: index, recognizer: recognizer, power: FakePower(paused: false))
        let running = Task { await indexer.run(concurrency: 2) }
        let deadline = ContinuousClock.now + .seconds(10)
        while recognizer.paths.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        running.cancel()
        await running.value
        #expect(await index.recognitionCounts().done == 0)
    }

    @Test func stopsWhenCancelled() async throws {
        let many = (0..<20).map { FileIndexTests.record("/u/\($0).jpg", kind: .image, bytes: 50_000, added: Double($0)) }
        let index = try await Self.index(many)
        let recognizer = FakeRecognizer(delay: .milliseconds(20))
        let indexer = ContentIndexer(index: index, recognizer: recognizer, power: FakePower(paused: false))
        let running = Task { await indexer.run() }
        let deadline = ContinuousClock.now + .seconds(10)
        while recognizer.paths.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(recognizer.paths.count >= 2)
        running.cancel()
        await running.value
        #expect(recognizer.paths.count < 20)
        // Cancelling isn't failing: the unfinished files are still waiting.
        let counts = await index.recognitionCounts()
        #expect(counts.done + counts.pending == 20)
    }

    /// Photos read before look-alikes existed get their prints without their text being read again.
    @Test func printsAreAddedToPhotosReadBefore() async throws {
        let index = try await Self.index(Self.images + [FileIndexTests.record("/u/icon.png", kind: .image, bytes: 50_000)])
        for file in await index.pendingRecognition(limit: 10) {
            try await index.setContent(id: file.id, text: "read before", labels: [])
        }
        let recognizer = FakeRecognizer()
        let printer = FakePrinter()
        await ContentIndexer(index: index, recognizer: recognizer, printer: printer, power: FakePower(paused: false)).run()
        #expect(recognizer.paths.isEmpty)
        #expect(Set(printer.paths) == ["/u/a.jpg", "/u/c.jpg"])
        let prints = await index.prints(ids: await index.lookAlikePhotos().map(\.id))
        #expect(prints.count == 2 && prints.values.allSatisfy { $0 == Data([1, 2, 3, 4]) })
        // Once printed, a photo isn't printed again.
        await ContentIndexer(index: index, recognizer: recognizer, printer: printer, power: FakePower(paused: false)).run()
        #expect(printer.paths.count == 2)
    }
}
