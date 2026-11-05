import Foundation
import Observation
import UnearthCore

/// The clean-up collections: what's in each, kept up to date as the Library and the disk change. The quick
/// ones fill in first; duplicates and look-alikes follow, at low priority and under the power rules. A look only
/// redoes what changed: apps after a new scan, duplicates and look-alikes when the rows they look at changed.
@MainActor @Observable
final class CollectionsModel {
    /// What a collection's pile shows.
    struct Summary: Equatable {
        let count: Int
        let bytes: Int64
        let preview: [IndexedFile]
    }

    /// Where to look, from the app model. Paths are real paths.
    struct Context: Sendable {
        let index: FileIndex
        /// The disk scan this look follows; apps are listed again only after a new one.
        let scan: UUID?
        let downloads: String
        let home: String
        let appFolders: [String]
        let systemLibrary: String
        let isInCodeProject: @Sendable (String) -> Bool
        let lastUsed: @Sendable (String) -> Date?
    }

    private(set) var summaries: [CollectionKind: Summary] = [:]
    /// The files of the collections that are lists of files.
    private(set) var files: [CollectionKind: [IndexedFile]] = [:]
    private(set) var duplicates: [DuplicateGroup] = []
    private(set) var lookAlikes: [LookAlikeGroup] = []
    /// Apps not opened in a while: ones Unearth can remove, and ones with a vendor's uninstaller.
    private(set) var apps: [InstalledApp] = []
    /// Apps Spotlight has no last-opened date for: shown, but not counted as unused.
    private(set) var undatedApps: [InstalledApp] = []
    /// While true, the sidebar says Unearth is looking for duplicates.
    private(set) var isWorking = false
    /// Becomes true once every collection has been looked at.
    private(set) var hasLooked = false
    /// How long the last look took, step by step, in seconds (for the debug report).
    @ObservationIgnored private(set) var timings: [String: Double] = [:]
    var settings: CollectionSettings {
        didSet {
            guard settings != oldValue else { return }
            if persists, let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: Self.settingsKey)
            }
            requestRefresh()
        }
    }

    /// Runs each time every collection has been looked at (the debug report uses it).
    @ObservationIgnored var onLooked: (@MainActor () -> Void)?
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var running: Task<Void, Never>?
    /// Which look `running` is, so a look that ends after `stop()` doesn't clear a newer one.
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var lookAgain = false
    /// A look waiting for the Library to settle.
    @ObservationIgnored private var waiting: Task<Void, Never>?
    /// What the looks found, before taking out what has left the disk since.
    @ObservationIgnored private var foundLists: [CollectionKind: [IndexedFile]] = [:]
    @ObservationIgnored private var foundApps: (unused: [InstalledApp], undated: [InstalledApp]) = ([], [])
    @ObservationIgnored private var foundDuplicates: [DuplicateGroup] = []
    /// What left the disk. A look under way may still find it, so it stays off the collections until it's back.
    @ObservationIgnored private var removed = RemovedPaths()
    /// What the last look saw, to tell what the next one must redo.
    @ObservationIgnored private var lastState: CollectionsState?
    /// Look-alike groups before exact copies are taken out, kept for when only the duplicates change.
    @ObservationIgnored private var foundLookAlikes: [LookAlikeGroup] = []
    private static let settingsKey = "collectionSettings"

    /// `persists` is false on the demo disk, whose settings are never saved.
    init(persists: Bool) {
        self.persists = persists
        if persists, let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(CollectionSettings.self, from: data) {
            settings = saved
        } else {
            settings = CollectionSettings()
        }
    }

    /// Looks again with what the app knows now, after `delay` without further asks (the Library changing file by
    /// file waits for a quiet moment). Asking while a look is under way queues one more.
    func refresh(_ context: Context, after delay: Duration = .zero) {
        self.context = context
        waiting?.cancel()
        waiting = nil
        guard delay > .zero else {
            requestRefresh()
            return
        }
        waiting = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.requestRefresh()
        }
    }

    /// Returns once nothing is left to look at (snapshot runs wait for this).
    func waitUntilLooked() async {
        while running != nil || !hasLooked {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    func stop() {
        waiting?.cancel()
        waiting = nil
        running?.cancel()
        running = nil
        runID = UUID()
        lookAgain = false
    }

    /// Settings › Privacy › Forget everything: nothing is left to show until the Library is built again.
    func clear() {
        stop()
        context = nil
        summaries = [:]
        files = [:]
        duplicates = []
        lookAlikes = []
        apps = []
        undatedApps = []
        hasLooked = false
        lastState = nil
        foundLists = [:]
        foundApps = ([], [])
        foundDuplicates = []
        foundLookAlikes = []
        removed = RemovedPaths()
    }

    /// Takes what just left the disk off every collection, so it's gone from their pages now: the next look can be
    /// minutes away.
    func remove(paths: [String]) {
        removed.insert(contentsOf: paths)
        showEverything()
    }

    /// Puts back what Undo returned to the disk, as the last look found it.
    func restore(paths: [String]) {
        removed.forget(paths)
        showEverything()
    }

    private func requestRefresh() {
        guard context != nil else { return }
        if running != nil {
            lookAgain = true
            return
        }
        let id = UUID()
        runID = id
        running = Task { [weak self] in
            await self?.lookWhileAsked(id)
        }
    }

    private func lookWhileAsked(_ id: UUID) async {
        repeat {
            lookAgain = false
            guard let context, !Task.isCancelled else { break }
            await look(context)
        } while lookAgain && !Task.isCancelled
        if runID == id { running = nil }
    }

    private func look(_ context: Context) async {
        isWorking = true
        defer { isWorking = false }
        let settings = self.settings
        let now = Date()
        let clock = ContinuousClock()
        var step = clock.now
        func lap(_ name: String) {
            let elapsed = (clock.now - step).components
            timings[name] = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            step = clock.now
        }

        let current = CollectionsState(
            scan: context.scan, duplicates: await context.index.duplicatesFingerprint(minBytes: settings.duplicateMinBytes),
            photos: await context.index.lookAlikesFingerprint(), settings: settings)
        let work = CollectionsWork.needed(since: lastState, now: current)
        // Anything back on disk counts again, however it got there.
        let known = removed.paths
        let back = await Task.detached(priority: .utility) { known.filter { FileManager.default.fileExists(atPath: $0) } }.value
        removed.forget(back)

        let lists = await Task.detached(priority: .utility) {
            let queries = CollectionQueries(index: context.index, downloads: context.downloads, settings: settings, now: now,
                                            lastUsed: context.lastUsed)
            var lists: [CollectionKind: [IndexedFile]] = [:]
            for kind in [CollectionKind.forgottenDownloads, .oldInstallers, .oldScreenshots, .bigOldVideos] {
                lists[kind] = await queries.files(kind)
            }
            return lists
        }.value
        guard !Task.isCancelled else { return }
        lap("lists")
        foundLists = lists
        showLists()

        if work.apps {
            // Listing every app and sizing it walks every bundle: once per disk scan, not per Library change.
            let (unused, undated) = await Task.detached(priority: .utility) {
                let installed = AppInventory.apps(in: context.appFolders, home: context.home, lastUsed: context.lastUsed,
                                                  systemLibrary: context.systemLibrary)
                let undated = installed.filter { $0.lastUsed == nil && !$0.isApple }.sorted { $0.movableBytes > $1.movableBytes }
                return (AppInventory.unused(installed, now: now, days: settings.unusedAppDays), undated)
            }.value
            guard !Task.isCancelled else { return }
            lap("apps")
            foundApps = (unused, undated)
            showApps()
        }

        if work.duplicates {
            let groups = await Task.detached(priority: .utility) {
                await DuplicateFinder(index: context.index, downloads: context.downloads,
                                      isInCodeProject: context.isInCodeProject).groups(minBytes: settings.duplicateMinBytes)
            }.value
            guard !Task.isCancelled else { return }
            lap("duplicates")
            foundDuplicates = groups
            showDuplicates()
        }

        if work.lookAlikes {
            let found = await Task.detached(priority: .utility) {
                await LookAlikeFinder(index: context.index, isInCodeProject: context.isInCodeProject).groups()
            }.value
            guard !Task.isCancelled else { return }
            lap("lookAlikes")
            foundLookAlikes = found
        }
        if work.lookAlikes || work.duplicates {
            showLookAlikes()
        }
        lastState = current
        hasLooked = true
        onLooked?()
    }

    // MARK: - On show

    private func isGone(_ file: IndexedFile) -> Bool { removed.covers(file.path) }

    /// What no look has found yet has nothing to show; the look that finds it leaves out what's gone.
    private func showEverything() {
        showLists()
        if summaries[.unusedApps] != nil { showApps() }
        if summaries[.duplicates] != nil { showDuplicates() }
        if summaries[.lookAlikes] != nil { showLookAlikes() }
    }

    private func showLists() {
        files = foundLists.mapValues { $0.filter { !isGone($0) } }
        for (kind, list) in files {
            summaries[kind] = Summary(count: list.count, bytes: list.reduce(0) { $0 + $1.bytes }, preview: Array(list.prefix(3)))
        }
    }

    private func showApps() {
        apps = foundApps.unused.filter { !removed.covers($0.path) }
        undatedApps = foundApps.undated.filter { !removed.covers($0.path) }
        summaries[.unusedApps] = Summary(count: apps.count, bytes: apps.reduce(0) { $0 + $1.movableBytes }, preview: [])
    }

    private func showDuplicates() {
        let groups = foundDuplicates.compactMap { $0.without(isGone) }
        duplicates = groups
        summaries[.duplicates] = Summary(
            count: groups.reduce(0) { $0 + $1.defaultSelection().count }, bytes: groups.reduce(0) { $0 + $1.extraBytes },
            preview: groups.prefix(3).map { $0.files[0] })
    }

    private func showLookAlikes() {
        let alike = Self.withoutCopies(foundLookAlikes, duplicates: duplicates).compactMap { $0.without(isGone) }
        lookAlikes = alike
        summaries[.lookAlikes] = Summary(
            count: alike.count,
            bytes: alike.reduce(0) { total, group in total + group.files.filter { $0.id != group.best }.reduce(0) { $0 + $1.bytes } },
            preview: alike.prefix(3).compactMap { group in group.files.first { $0.id == group.best } })
    }
}

extension CollectionsModel {
    /// Look-alike groups that are nothing but exact copies of one file are already under Duplicates.
    nonisolated static func withoutCopies(_ groups: [LookAlikeGroup], duplicates: [DuplicateGroup]) -> [LookAlikeGroup] {
        var copyOf: [Int64: String] = [:]
        for group in duplicates {
            for file in group.files { copyOf[file.id] = group.id }
        }
        return groups.filter { group in
            Set(group.files.map { copyOf[$0.id] ?? String($0.id) }).count > 1
        }
    }
}
