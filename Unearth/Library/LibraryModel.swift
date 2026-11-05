import Foundation
import Observation
import UnearthCore

enum LibraryStatus: Equatable {
    case idle
    case indexing(files: Int)
    case recognizing(done: Int, total: Int)
    case ready
    case unavailable
}

/// The Library: Unearth's on-device catalog of the user's files, kept fresh as folders change,
/// with text and objects read from images in the background.
@MainActor @Observable
final class LibraryModel {
    static let pageSize = 300
    static let searchLimit = 500

    private(set) var kinds: [KindSummary] = []
    private(set) var sources: [SourceSummary] = []
    private(set) var recent: [IndexedFile] = []
    /// The four newest files of each kind, for Home's tiles.
    private(set) var newest: [FileKind: [IndexedFile]] = [:]
    /// The three newest files from each of the biggest download sources, for their cards.
    private(set) var sourcePreviews: [String: [IndexedFile]] = [:]
    /// Files Vision found text in: Copy Text is offered for these.
    private(set) var textIDs: Set<Int64> = []
    private(set) var status: LibraryStatus = .idle
    /// Changes whenever the index does, so open screens know to reload.
    private(set) var revision = 0
    /// How the last full pass went.
    private(set) var lastIndexStats: IndexStats?
    /// Runs after the index changes, and when reading images finishes (photos then have their prints).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    let index: FileIndex?
    @ObservationIgnored private let jobs = SerialJobs()
    @ObservationIgnored private var indexer: Indexer?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var recognition: Task<Void, Never>?
    @ObservationIgnored private var recognitionRun: UUID?
    @ObservationIgnored private var roots: [String] = []
    /// The folders the user has in the Library, including ones missing right now (an unplugged drive).
    @ObservationIgnored private var configured: [String] = []
    @ObservationIgnored private var changedFolders: Set<String> = []
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var fullPassQueued = false

    init(databaseURL: URL) {
        index = try? FileIndex(url: databaseURL)
        if index == nil { status = .unavailable }
    }

    var isIndexing: Bool {
        if case .indexing = status { true } else { false }
    }

    func count(of kind: FileKind) -> Int { kinds.first { $0.kind == kind }?.count ?? 0 }
    func bytes(of kind: FileKind) -> Int64 { kinds.first { $0.kind == kind }?.bytes ?? 0 }

    /// Indexes `roots` (what's already known shows at once), then watches them and reads images. An earlier
    /// start is stopped and waited for first. Files of folders in `configured` that are missing right now stay.
    func start(roots: [String], configured: [String], excluded: [String], packageSize: @escaping @Sendable (String) -> Int64?) async {
        guard let index else { return }
        await stop()
        await jobs.perform { [self] in
            // Folders the user took out of the Library take their files with them.
            let dropped = self.configured.filter { old in !configured.contains { Paths.isSameOrInside(old, $0) } }
            if !dropped.isEmpty { _ = try? await index.removeUnseen(under: dropped, generation: .max) }
            self.roots = roots
            self.configured = configured
            await reloadSummaries()
            let indexer = Indexer(index: index, excludedPaths: excluded, packageSize: packageSize)
            self.indexer = indexer
            status = .indexing(files: 0)
            let stats = try? await indexer.index(roots: roots) { count in
                Task { @MainActor [weak self] in
                    if self?.isIndexing == true { self?.status = .indexing(files: count) }
                }
            }
            guard !Task.isCancelled else { return }
            lastIndexStats = stats
            status = .ready
            await reloadSummaries()
            let watcher = FolderWatcher(paths: roots) { [weak self] folders in
                Task { @MainActor in self?.foldersChanged(folders) }
            } onOverflow: { [weak self] in
                Task { @MainActor in self?.reindex() }
            }
            watcher.start()
            self.watcher = watcher
            startRecognition()
        }
    }

    /// Stops watching and reading, cancels index work, and returns once all of it has stopped.
    func stop() async {
        watcher?.stop()
        watcher = nil
        await stopRecognition()
        await jobs.cancelAll()
        changedFolders = []
        refreshQueued = false
        fullPassQueued = false
    }

    /// The first files passing the query's filters: `limit` of them from `offset`.
    func files(matching query: SearchQuery, sort: FileSort, limit: Int, offset: Int) async -> [IndexedFile] {
        await index?.files(matching: query, sort: sort, limit: limit, offset: offset) ?? []
    }

    /// The query's files split into months, folders or download sources.
    func sections(matching query: SearchQuery, by grouping: FileGrouping, calendar: Calendar) async -> [FileSection] {
        await index?.sections(matching: query, by: grouping, calendar: calendar) ?? []
    }

    /// How to split the query's files, judged from how they're spread.
    func fittingGrouping(matching query: SearchQuery, calendar: Calendar) async -> FileGrouping {
        await index?.fittingGrouping(matching: query, calendar: calendar) ?? .date
    }

    func ids(matching query: SearchQuery) async -> [Int64] {
        await index?.ids(matching: query) ?? []
    }

    /// These files as they are now; ones gone from the Library are left out.
    func files(ids: [Int64]) async -> [IndexedFile] {
        await index?.files(ids: ids) ?? []
    }

    func search(_ query: SearchQuery) async -> [SearchHit] {
        await index?.search(query, limit: Self.searchLimit) ?? []
    }

    /// Lists these folders again, after an action found something gone or moved.
    func refresh(_ folders: [String]) {
        foldersChanged(folders)
    }

    /// Lists these folders again and returns once that's done (snapshot runs check the result).
    func refreshAndWait(_ folders: [String]) async {
        await jobs.perform { [self] in
            guard let indexer, (try? await indexer.refresh(directories: folders)) ?? 0 > 0 else { return }
            await reloadSummaries()
        }
    }

    /// Forgets files an action found missing at once, then lists their folders again.
    func drop(_ files: [IndexedFile]) async {
        guard let index, indexer != nil else { return }
        await jobs.perform { [self] in
            try? await index.remove(paths: files.map(\.path))
            await reloadSummaries()
        }
        foldersChanged(Array(Set(files.map(\.parent))))
    }

    /// Settings › Privacy › Forget everything. Work in progress is stopped and waited for first, so nothing
    /// writes into the emptied index; it's built again the next time Unearth opens.
    func forget() async {
        await stop()
        indexer = nil
        try? await index?.eraseAll()
        kinds = []
        sources = []
        recent = []
        newest = [:]
        sourcePreviews = [:]
        textIDs = []
        revision += 1
        status = .idle
    }

    // MARK: - Keeping fresh

    /// Folders reported while a refresh waits are merged into it.
    private func foldersChanged(_ folders: [String]) {
        guard indexer != nil else { return }
        changedFolders.formUnion(folders)
        guard !refreshQueued else { return }
        refreshQueued = true
        jobs.add { [self] in
            refreshQueued = false
            let folders = Array(changedFolders)
            changedFolders = []
            guard let indexer, !folders.isEmpty else { return }
            let changed = (try? await indexer.refresh(directories: folders)) ?? 0
            guard changed > 0, !Task.isCancelled else { return }
            await reloadSummaries()
            if recognition == nil { startRecognition() }
        }
    }

    /// macOS dropped events: one full pass catches up, however many times it's asked for while waiting.
    private func reindex() {
        guard indexer != nil, !fullPassQueued else { return }
        fullPassQueued = true
        jobs.add { [self] in
            fullPassQueued = false
            guard let indexer, let stats = try? await indexer.index(roots: roots),
                  stats.changed + stats.removed > 0, !Task.isCancelled else { return }
            await reloadSummaries()
            if recognition == nil { startRecognition() }
        }
    }

    func reloadSummaries() async {
        guard let index else { return }
        kinds = await index.kindSummaries()
        sources = await index.sourceSummaries()
        recent = await index.recent(limit: 12)
        var newest: [FileKind: [IndexedFile]] = [:]
        for summary in kinds where summary.count > 0 {
            newest[summary.kind] = await index.files(kind: summary.kind, source: nil, parent: nil, sort: .added, limit: 4, offset: 0)
        }
        self.newest = newest
        var previews: [String: [IndexedFile]] = [:]
        for summary in sources.prefix(12) {
            var query = SearchQuery()
            query.source = summary.source
            previews[summary.source] = await index.files(matching: query, sort: .added, limit: 3, offset: 0)
        }
        sourcePreviews = previews
        textIDs = await index.idsWithText()
        revision += 1
        onChange?()
    }

    /// Reads images at utility priority, two at a time, and reports progress while it does. (Background
    /// priority read about 46 images a minute on a real Mac: a day for a large library.) Only one
    /// reader ever runs.
    private func startRecognition() {
        guard let index else { return }
        recognition?.cancel()
        let run = UUID()
        recognitionRun = run
        let reader = ContentIndexer(index: index, recognizer: VisionRecognizer(), printer: VisionRecognizer())
        let work = Task.detached(priority: .utility) { await reader.run(concurrency: 2) }
        recognition = Task { [weak self] in
            let progress = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.showRecognitionProgress()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            progress.cancel()
            guard let self, self.recognitionRun == run else { return }
            await self.showRecognitionProgress()
            self.recognition = nil
            self.recognitionRun = nil
            if let index = self.index { self.textIDs = await index.idsWithText() }
            self.onChange?()
        }
    }

    private func stopRecognition() async {
        let task = recognition
        recognition = nil
        recognitionRun = nil
        task?.cancel()
        await task?.value
    }

    private func showRecognitionProgress() async {
        guard let index else { return }
        let counts = await index.recognitionCounts()
        status = counts.pending == 0 ? .ready : .recognizing(done: counts.done, total: counts.done + counts.pending)
    }
}
