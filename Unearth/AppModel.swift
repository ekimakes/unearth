import AppKit
import Observation
import UnearthCore

/// Every screen the window can show.
enum SidebarItem: Hashable {
    case home, recents
    case kind(FileKind)
    case downloadedFrom
    /// One download source's files, opened from Home or Downloaded From.
    case source(String)
    case storage, systemData, junk, developer, largeFiles, diskMap
    /// The Clean up overview: every collection as a pile.
    case cleanUp
    /// One clean-up collection's review page.
    case collection(CollectionKind)
    /// A folder, by real path.
    case place(String)

    /// The kinds the Library lists, in sidebar order.
    static let libraryKinds: [FileKind] = [.image, .video, .screenshot, .document, .audio, .archive, .app]
}

enum ScanPhase: Equatable {
    case idle
    case scanning(ScanProgress)
    case ready
    case failed(String)
}

/// How far a move to the Trash has got.
struct TrashProgress: Equatable {
    var done: Int
    let total: Int
}

/// Everything the window shows, and the only place that starts scans and cleanups.
@MainActor @Observable
final class AppModel {
    let options: LaunchOptions
    /// Display path of the home folder used by cleanup rules and safety checks.
    let homePath: String

    var phase: ScanPhase = .idle
    /// A scan is checking the disk behind what's on screen, and nothing waits for it.
    private(set) var isRefreshing = false
    var volumes: VolumeInventory?
    var tree: ScanTree?
    var breakdown: StorageBreakdown?
    var plan: CleanupPlan?
    var selection: Set<CleanupItem.ID> = []
    var lastOutcome: CleanupOutcome?
    var lastFailures: [CleanupFailure] = []
    /// Files on their way to the Trash, while any are.
    private(set) var trashProgress: TrashProgress?
    var history: [HistoryEntry] = []
    var sidebarSelection: SidebarItem? = .home
    /// A folder (display path) the Disk Map should open on, set by a click on the strata.
    var diskMapFocus: String?
    /// What's typed in the search field; results replace the screen while it isn't empty.
    var searchText = ""
    /// Bumped to move the keyboard to the search field (⌘K, Home's search bar).
    private(set) var searchFocusRequests = 0
    var hasFullDiskAccess = FullDiskAccess.isGranted()
    /// The file shown in Quick Look, if any.
    var previewURL: URL?
    var settings: CleanupSettings {
        didSet {
            saveSettings()
            Task { await replan() }
        }
    }

    /// The Library: every file in the user's folders, searchable.
    let library: LibraryModel
    /// Duplicates, forgotten downloads, unused apps and the other clean-up collections.
    let collections: CollectionsModel
    @ObservationIgnored private var libraryStarted = false
    /// The disk changed during a scan, so another follows it.
    @ObservationIgnored private var scanAgain = false

    private let runner = ProcessCommandRunner()
    /// Moves an app installed for all users through the macOS password prompt; typing a password can take a while.
    private let adminMover = AdminMover(runner: ProcessCommandRunner(timeout: .seconds(600)))
    private let historyStore: CleanupHistory
    private let savedScan: SavedScan
    /// What the user ticked or unticked themselves, so a replan doesn't undo it.
    @ObservationIgnored private var selectionMemory = SelectionMemory()
    private static let knowledgeBase = try? KnowledgeBase.bundled()

    init(options: LaunchOptions) {
        self.options = options
        homePath = options.home ?? NSHomeDirectory()
        settings = Self.loadSettings()
        historyStore = CleanupHistory(fileURL: Self.historyURL(options))
        savedScan = SavedScan(fileURL: Self.savedScanURL(options))
        library = LibraryModel(databaseURL: Self.indexURL(options))
        collections = CollectionsModel(persists: options.scanRoot == nil)
        leftOutFolders = options.scanRoot == nil ? LibraryFolders.leftOut : []
        // The Library changes file by file; the collections look again once it has been quiet for a while.
        library.onChange = { [weak self] in self?.refreshCollections(soon: true) }
        #if DEBUG
        collections.onLooked = { [weak self] in self?.writeReport() }
        #endif
    }

    var isScanning: Bool {
        if case .scanning = phase { true } else { false }
    }

    /// What "You can safely free" promises: Safe items that go to the Trash.
    var safeToFree: Int64 {
        plan.map { $0.totalBytes(of: $0.defaultSelection()) } ?? 0
    }

    func total(of section: CleanupSection) -> Int64 {
        plan?.items(in: section).reduce(0) { $0 + $1.bytes } ?? 0
    }

    // MARK: - Scanning

    /// Opening the app: what it already knows shows at once, and the disk is checked behind it unless that was
    /// just done. Scanning a full Mac takes about a minute.
    func open() async {
        hasFullDiskAccess = FullDiskAccess.isGranted()
        phase = .scanning(ScanProgress(files: 0, directories: 0, bytes: 0, currentPath: ""))
        await library.reloadSummaries()
        let saved = savedScan
        let loaded = await Task.detached { saved.load() }.value
        guard let loaded, loaded.tree.rootPath == scanRootPath, await loadVolumes() else {
            phase = .idle
            await startScan()
            return
        }
        await show(loaded.tree)
        startLibraryOnce()
        refreshCollections()
        if !loaded.isFresh || loaded.hadFullDiskAccess != hasFullDiskAccess {
            await startScan()
        }
    }

    func startScan() async {
        guard !isScanning, !isRefreshing else {
            scanAgain = true
            return
        }
        hasFullDiskAccess = FullDiskAccess.isGranted()
        // With results on screen the scan runs behind them: nothing waits for it, and it gives way to everything else.
        let quiet = tree != nil
        if quiet {
            isRefreshing = true
        } else {
            phase = .scanning(ScanProgress(files: 0, directories: 0, bytes: 0, currentPath: ""))
        }
        do {
            if options.scanRoot == nil {
                volumes = try await VolumeInventory.load(runner: runner)
            }
            var scanOptions = ScanOptions(rootPath: scanRootPath, displayRoot: "/")
            scanOptions.priority = quiet ? .utility : .userInitiated
            let tree = try await DiskScanner().scan(scanOptions) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.isScanning else { return }
                    self.phase = .scanning(progress)
                }
            }
            await show(tree)
            if !scanAgain { save(tree) }
            #if DEBUG
            writeReport()
            #endif
            if libraryStarted {
                refreshCollections()
            } else {
                startLibraryOnce()
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
        isRefreshing = false
        if scanAgain {
            scanAgain = false
            Task { await startScan() }
        }
    }

    private var scanRootPath: String { options.scanRoot ?? "/System/Volumes/Data" }

    private func loadVolumes() async -> Bool {
        guard options.scanRoot == nil else { return true }
        guard let volumes = try? await VolumeInventory.load(runner: runner) else { return false }
        self.volumes = volumes
        return true
    }

    /// Puts a scan on screen: its breakdown, and a plan made from it.
    private func show(_ tree: ScanTree) async {
        let volumes = self.volumes ?? DemoVolumes.make(scannedBytes: tree.node(tree.rootID).totalBytes)
        let home = homePath
        let breakdown = await Task.detached { StorageBreakdown.compute(tree: tree, volumes: volumes, homePath: home) }.value
        self.volumes = volumes
        self.tree = tree
        self.breakdown = breakdown
        await replan()
        await refreshHistory()
        phase = .ready
    }

    private func save(_ tree: ScanTree) {
        let saved = savedScan
        let fullDiskAccess = hasFullDiskAccess
        Task.detached(priority: .utility) { try? saved.save(tree, fullDiskAccess: fullDiskAccess) }
    }

    private func startLibraryOnce() {
        guard !libraryStarted else { return }
        libraryStarted = true
        Task { await startLibrary() }
    }

    func replan() async {
        guard let tree, let knowledgeBase = Self.knowledgeBase else { return }
        let context = DetectionContext(
            tree: tree, homePath: homePath, now: Date(), settings: settings, apps: AppNameResolver.current(),
            runner: runner, knowledgeBase: knowledgeBase)
        let planned = await CleanupPlanner.standard().plan(context)
        let largeFiles = await largeFileItems(in: tree).filter { file in
            !planned.items.contains { $0.paths.contains { Paths.isSameOrInside(file.paths[0], $0) } }
        }
        let plan = CleanupPlan(items: planned.items + largeFiles)
        self.plan = plan
        selection = selectionMemory.apply(to: plan)
    }

    private func largeFileItems(in tree: ScanTree) async -> [CleanupItem] {
        let scanRoot = options.scanRoot
        let query = LargeFilesQuery(
            minimumBytes: settings.largeFileThreshold,
            notOpenedForDays: settings.oldFileAgeDays > 0 ? settings.oldFileAgeDays : nil, now: Date(), homePath: homePath,
            lastUsed: { path in SpotlightLastUsed.date(forPath: scanRoot.map { $0 + path } ?? path) })
        let safety = SafetyGuard(homePath: homePath, neverTouch: settings.neverTouch)
        return await Task.detached { query.items(from: tree, safetyGuard: safety) }.value
    }

    // MARK: - Library

    /// Folder sizes from the last disk scan, by real path, for use off the main thread.
    var scannedSizes: @Sendable (String) -> Int64? {
        let tree = tree
        let scanRoot = options.scanRoot
        return { path in
            let display = scanRoot.map { path.hasPrefix($0 + "/") ? String(path.dropFirst($0.count)) : path } ?? path
            return tree?.node(atPath: display)?.totalBytes
        }
    }

    /// A folder's size from the last disk scan, by real path.
    func folderSize(_ path: String) -> Int64? {
        scannedSizes(path)
    }

    func requestSearchFocus() {
        searchFocusRequests += 1
    }

    func search(_ text: String) {
        searchText = text
        requestSearchFocus()
    }

    /// The Places in the sidebar: the home folder and the usual folders in it.
    var places: [String] {
        let home = realPath(homePath)
        return [home] + LibraryFolders.standard.map { Paths.join(home, $0) }.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// The usual places in the home folder, and Applications.
    var defaultLibraryFolders: [String] {
        let home = realPath(homePath)
        let applications = options.scanRoot.map { Paths.join($0, "Applications") } ?? "/Applications"
        return (LibraryFolders.standard.map { Paths.join(home, $0) } + [applications]).filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// The folders the Library covers that are on this Mac right now.
    var libraryFolders: [String] {
        configuredLibraryFolders.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// The defaults and any folders the user added, even ones missing right now (an unplugged drive).
    /// A folder inside another is covered by it.
    var configuredLibraryFolders: [String] {
        let all = defaultLibraryFolders + LibraryFolders.added
        return all.enumerated().filter { index, folder in
            !all.enumerated().contains { other, outer in
                other != index && Paths.isSameOrInside(folder, outer) && (folder != outer || other < index)
            }
        }.map(\.element)
    }

    /// Settings › Library › Add or Remove: index the new set of folders.
    func setAddedLibraryFolders(_ folders: [String]) async {
        LibraryFolders.added = folders
        await startLibrary()
    }

    /// Folders the Library skips. On the demo disk they're never saved.
    private(set) var leftOutFolders: [String] = []

    /// Settings › Library › Leave out: index again without these folders; their files leave the Library.
    func setLeftOutFolders(_ folders: [String]) async {
        leftOutFolders = folders
        if options.scanRoot == nil { LibraryFolders.leftOut = folders }
        await startLibrary()
    }

    /// Settings › Privacy › Forget everything. The index is built again the next time Unearth opens.
    func forgetLibrary() async {
        collections.clear()
        savedScan.forget()
        await library.forget()
    }

    func startLibrary() async {
        // A left-out folder takes any Library folder inside it out too, so its files leave the index; one deeper
        // inside a Library folder is skipped by the index's exclusions.
        let leftOut = leftOutFolders
        let kept: ([String]) -> [String] = { folders in
            folders.filter { folder in !leftOut.contains { Paths.isSameOrInside(folder, $0) } }
        }
        // Package sizes come from the disk scan when it covered them.
        await library.start(roots: kept(libraryFolders), configured: kept(configuredLibraryFolders),
                            excluded: [Paths.join(realPath(homePath), "Library")] + leftOut, packageSize: scannedSizes)
        refreshCollections()
        #if DEBUG
        writeReport()
        #endif
    }

    /// Looks for duplicates, forgotten downloads, unused apps and the rest again, with the latest scan; `soon`
    /// waits for a quiet moment first.
    func refreshCollections(soon: Bool = false) {
        guard let index = library.index, let tree else { return }
        let scanRoot = options.scanRoot
        let home = realPath(homePath)
        let homeDisplay = homePath
        let isInCodeProject: @Sendable (String) -> Bool = { path in
            let display = scanRoot.map { path.hasPrefix($0 + "/") ? String(path.dropFirst($0.count)) : path } ?? path
            return tree.isInsideCodeProject(display, home: homeDisplay)
        }
        let lastUsed: @Sendable (String) -> Date?
        if scanRoot == nil {
            lastUsed = { SpotlightLastUsed.date(forPath: $0) }
        } else {
            // Spotlight doesn't look inside the demo disk; there, when a file last changed stands in.
            lastUsed = { (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate]) as? Date }
        }
        let applications = scanRoot.map { Paths.join($0, "Applications") } ?? "/Applications"
        collections.refresh(CollectionsModel.Context(
            index: index, scan: tree.id, downloads: Paths.join(home, "Downloads"), home: home,
            appFolders: [applications, Paths.join(home, "Applications")],
            systemLibrary: scanRoot.map { Paths.join($0, "Library") } ?? "/Library",
            isInCodeProject: isInCodeProject, lastUsed: lastUsed), after: soon ? .seconds(20) : .zero)
    }

    // MARK: - Selection

    func toggle(_ id: CleanupItem.ID) {
        let selected = !selection.contains(id)
        if selected { selection.insert(id) } else { selection.remove(id) }
        selectionMemory.record(id, selected: selected)
    }

    func selectedIDs(in section: CleanupSection) -> Set<CleanupItem.ID> {
        Set((plan?.items(in: section) ?? []).map(\.id)).intersection(selection)
    }

    // MARK: - Cleaning

    func moveToTrash(_ ids: Set<CleanupItem.ID>) async {
        guard let plan else { return }
        await move(plan.items.filter { ids.contains($0.id) }.map(realItem))
        await afterCleanup()
    }

    /// Moves one hand-picked folder or file (from the Disk Map or Large Files) to the Trash.
    func moveToTrash(_ items: [CleanupItem]) async {
        await move(items.map(realItem))
        await afterCleanup()
    }

    /// Moves items to the Trash with their progress on screen. What moved leaves the plan right away, since the
    /// scan that follows takes a while.
    private func move(_ items: [CleanupItem]) async {
        trashProgress = TrashProgress(done: 0, total: items.count)
        let step = max(1, items.count / 100)
        let outcome = await makeEngine().moveToTrash(items) { [weak self] done in
            guard done % step == 0 else { return }
            Task { @MainActor in self?.trashProgress?.done = done }
        }
        trashProgress = nil
        lastOutcome = outcome
        lastFailures = outcome.failures
        let moved = Set(outcome.entries.filter { $0.state == .inTrash }.compactMap(\.originalPath))
        if let plan, !moved.isEmpty {
            self.plan = CleanupPlan(items: plan.items.filter { !$0.paths.allSatisfy { moved.contains(realPath($0)) } })
        }
    }

    // MARK: - Acting on Library files

    static let goneReason = "It was moved or deleted since Unearth last looked."
    static let offlineReason = "It's on a drive that isn't connected right now."

    /// Splits off files that aren't on disk. Ones that are gone leave the Library; ones on a drive that isn't
    /// plugged in stay, since they come back with the drive.
    private func splitMissing(_ files: [IndexedFile]) -> (present: [IndexedFile], gone: [CleanupFailure]) {
        let missing = files.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard !missing.isEmpty else { return (files, []) }
        let offline = missing.filter { DiskUsage.isOnDisconnectedVolume($0.path) }
        let deleted = missing.filter { !DiskUsage.isOnDisconnectedVolume($0.path) }
        if !deleted.isEmpty { Task { await library.drop(deleted) } }
        let failures = missing.map { file in
            CleanupFailure(title: file.name, path: file.path,
                           reason: offline.contains(file) ? Self.offlineReason : Self.goneReason)
        }
        let absent = Set(missing.map(\.id))
        return (files.filter { !absent.contains($0.id) }, failures)
    }

    /// Runs `action` on the files still there; any that are gone are reported.
    private func withFilesStillThere(_ files: [IndexedFile], _ action: ([IndexedFile]) -> Void) {
        let (present, gone) = splitMissing(files)
        if !gone.isEmpty {
            lastOutcome = nil
            lastFailures = gone
        }
        if !present.isEmpty { action(present) }
    }

    func open(_ files: [IndexedFile]) {
        guard files.count <= Self.opensWithoutAsking || confirmOpening(files.count) else { return }
        withFilesStillThere(files) { $0.forEach { NSWorkspace.shared.open(URL(fileURLWithPath: $0.path)) } }
    }

    /// From more than this many files, opening asks first: each one starts its app or adds a window.
    private static let opensWithoutAsking = 20

    private func confirmOpening(_ count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Open \(count.formatted()) files?"
        alert.informativeText = "Each one opens in its own app or window, which can take a while."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func quickLook(_ file: IndexedFile) {
        withFilesStillThere([file]) { previewURL = URL(fileURLWithPath: $0[0].path) }
    }

    /// Copies the text found in these images, one image's text after another.
    func copyText(_ files: [IndexedFile]) async {
        guard let index = library.index else { return }
        let texts = await index.recognizedText(ids: files.map(\.id))
        let joined = files.compactMap { texts[$0.id] }.joined(separator: "\n\n")
        guard !joined.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(joined, forType: .string)
    }

    func revealInFinder(_ files: [IndexedFile]) {
        withFilesStillThere(files) { NSWorkspace.shared.activateFileViewerSelecting($0.map { URL(fileURLWithPath: $0.path) }) }
    }

    /// Moves files picked in the Library to the Trash. Their paths are real already, so they aren't mapped.
    /// Files already gone are dropped from the Library; they only get a message when nothing else was moved.
    func moveFilesToTrash(_ picked: [IndexedFile]) async {
        trashProgress = TrashProgress(done: 0, total: picked.count)
        let (files, gone) = splitMissing(picked)
        guard !files.isEmpty else {
            trashProgress = nil
            lastOutcome = nil
            lastFailures = gone
            return
        }
        // What the Trash gives back is the space on this Mac, not the file's length (iCloud-only files take none).
        let picked = files.map { ($0.path, $0.fileExtension.isEmpty && $0.kind == .other) }
        let items = await Task.detached {
            picked.map { path, isFolder in
                CleanupItem.picked(path: path, bytes: DiskUsage.onDisk(path),
                                   what: isFolder ? "Something you picked in your Library." : "A file you picked in your Library.")
            }
        }.value
        await move(items)
        library.refresh(Array(Set(files.map(\.parent))))
        await afterCleanup()
    }

    func runTool(_ item: CleanupItem) async {
        lastOutcome = await makeEngine().runTool(item)
        lastFailures = lastOutcome?.failures ?? []
        await afterCleanup()
    }

    func undoLastCleanup() async {
        guard let outcome = lastOutcome else { return }
        lastFailures = await makeEngine().undo(outcome.entries.filter { $0.state == .inTrash }.map(\.id))
        lastOutcome = nil
        await afterCleanup()
    }

    func undo(_ ids: [UUID]) async {
        lastFailures = await makeEngine().undo(ids)
        await afterCleanup()
    }

    func deletePermanently(_ ids: [UUID]) async {
        lastFailures = await makeEngine().deletePermanently(ids)
        if let outcome = lastOutcome, Set(outcome.entries.map(\.id)).isSubset(of: Set(ids)) { lastOutcome = nil }
        await refreshHistory()
    }

    func refreshHistory() async {
        try? await historyStore.reconcile { path in
            var info = stat()
            return lstat(path, &info) == 0
        }
        history = await historyStore.all()
    }

    private func afterCleanup() async {
        await refreshHistory()
        savedScan.markOutdated()
        Task { await startScan() }
    }

    private func makeEngine() -> CleanupEngine {
        let home = realPath(homePath)
        return CleanupEngine(
            safetyGuard: SafetyGuard(homePath: home, neverTouch: settings.neverTouch.map(realPath)),
            // An app moved with an administrator's password goes back to Applications the same way.
            trash: SystemTrash(admin: adminMover, home: home), runner: runner, history: historyStore, dryRun: options.dryRun,
            isRunning: RunningApps.isRunning)
    }

    // MARK: - Collections

    /// Moves files picked on a collection's review page to the Trash, each with the collection's explanation.
    func trash(collection: CollectionKind, files picked: [IndexedFile]) async {
        trashProgress = TrashProgress(done: 0, total: picked.count)
        let (files, gone) = splitMissing(picked)
        guard !files.isEmpty else {
            trashProgress = nil
            lastOutcome = nil
            lastFailures = gone
            return
        }
        let chosen = files
        let items = await Task.detached { chosen.map { collection.item(for: $0, onDiskBytes: DiskUsage.onDisk($0.path)) } }.value
        await move(items)
        library.refresh(Array(Set(files.map(\.parent))))
        await afterCleanup()
    }

    /// Moves an unused app and what it keeps in the home folder to the Trash. The Safety Guard lets this one
    /// app and its own preferences file through; an app installed for all users asks for a password.
    func uninstall(_ app: InstalledApp) async {
        guard let items = Uninstall.items(for: app) else { return }
        let home = realPath(homePath)
        let engine = CleanupEngine(
            safetyGuard: SafetyGuard(homePath: home, neverTouch: settings.neverTouch.map(realPath),
                                     uninstalling: Uninstall.exception(for: app, home: home)),
            trash: UninstallTrash(appPath: app.path, home: home, base: SystemTrash(admin: adminMover, home: home), admin: adminMover),
            runner: runner, history: historyStore, dryRun: options.dryRun, isRunning: RunningApps.isRunning)
        lastOutcome = await Uninstall.perform(items, engine: engine)
        lastFailures = lastOutcome?.failures ?? []
        await afterCleanup()
    }

    /// On the startup disk display paths are real paths; on a fake disk they're mapped into it.
    func realPath(_ displayPath: String) -> String {
        guard options.scanRoot != nil, let tree else { return displayPath }
        return tree.realPath(forDisplayPath: displayPath)
    }

    private func realItem(_ item: CleanupItem) -> CleanupItem {
        options.scanRoot == nil ? item : item.withPaths(item.paths.map(realPath))
    }

    #if DEBUG
    /// `-UnearthReportFile <path>`: the scan's numbers as JSON, so a real-disk run can be checked.
    private func writeReport() {
        guard let path = options.reportFile, let tree, let breakdown else { return }
        let elapsed = tree.stats.elapsed.components
        let report: [String: Any] = [
            "scanSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
            "files": tree.stats.files, "directories": tree.stats.directories,
            "inaccessibleDirectories": tree.stats.inaccessibleDirectories, "cloudOnlyFiles": tree.stats.cloudOnlyFiles,
            "fullDiskAccess": hasFullDiskAccess, "dryRun": options.dryRun,
            "used": breakdown.used, "free": breakdown.free, "purgeable": breakdown.purgeable, "overcount": breakdown.overcount,
            "segments": Dictionary(uniqueKeysWithValues: breakdown.segments.map { ($0.key.rawValue, $0.value) }),
            "systemData": Dictionary(uniqueKeysWithValues: breakdown.systemData.map { ($0.key.rawValue, $0.value) }),
            "safeToFree": safeToFree,
            "library": [
                "folders": libraryFolders, "status": String(describing: library.status),
                "indexedFiles": library.lastIndexStats?.files ?? 0,
                "indexSeconds": library.lastIndexStats.map { Double($0.elapsed.components.seconds) + Double($0.elapsed.components.attoseconds) / 1e18 } ?? 0,
                "kinds": Dictionary(uniqueKeysWithValues: library.kinds.map { ($0.kind.rawValue, ["count": $0.count, "bytes": $0.bytes]) }),
                "sources": Dictionary(uniqueKeysWithValues: library.sources.map { ($0.source, $0.count) }),
            ] as [String: Any],
            "collections": [
                "looked": collections.hasLooked,
                "summaries": Dictionary(uniqueKeysWithValues: collections.summaries.map {
                    ($0.key.rawValue, ["count": $0.value.count, "bytes": $0.value.bytes])
                }),
                "duplicateGroups": collections.duplicates.map { $0.files.map(\.name) },
                "lookAlikeGroups": collections.lookAlikes.map { $0.files.map(\.name) },
                "unusedApps": collections.apps.map { [$0.name, $0.vendorFolder ?? ""] },
                "undatedApps": collections.undatedApps.count,
                "seconds": collections.timings,
            ] as [String: Any],
            "items": (plan?.items ?? []).map {
                ["section": $0.section.rawValue, "group": $0.group, "title": $0.title, "bytes": $0.bytes,
                 "safety": $0.safety.rawValue, "blocked": $0.blockedReason != nil] as [String: Any]
            },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
    #endif

    // MARK: - Persistence

    private static func loadSettings() -> CleanupSettings {
        guard let data = UserDefaults.standard.data(forKey: "cleanupSettings"),
              let settings = try? JSONDecoder().decode(CleanupSettings.self, from: data) else { return CleanupSettings() }
        return settings
    }

    private func saveSettings() {
        guard options.scanRoot == nil else { return }
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "cleanupSettings") }
    }

    private static func indexURL(_ options: LaunchOptions) -> URL {
        if let root = options.scanRoot {
            return URL(fileURLWithPath: root).deletingLastPathComponent().appendingPathComponent("unearth-demo-index.sqlite")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Unearth/index.sqlite")
    }

    private static func savedScanURL(_ options: LaunchOptions) -> URL {
        if let root = options.scanRoot {
            return URL(fileURLWithPath: root).deletingLastPathComponent().appendingPathComponent("unearth-demo-last-scan.bin")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Unearth/last-scan.bin")
    }

    private static func historyURL(_ options: LaunchOptions) -> URL {
        if let root = options.scanRoot {
            return URL(fileURLWithPath: root).deletingLastPathComponent().appendingPathComponent("unearth-demo-history.json")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Unearth/history.json")
    }
}

/// Believable volume numbers for a fake disk, scaled to what was scanned.
enum DemoVolumes {
    static func make(scannedBytes data: Int64) -> VolumeInventory {
        let volumes = [
            APFSVolume(deviceIdentifier: "demo1", name: "Macintosh HD", roles: ["System"], capacityInUse: data / 4),
            APFSVolume(deviceIdentifier: "demo2", name: "Data", roles: ["Data"], capacityInUse: data),
            APFSVolume(deviceIdentifier: "demo3", name: "VM", roles: ["VM"], capacityInUse: data / 10),
            APFSVolume(deviceIdentifier: "demo4", name: "Preboot", roles: ["Preboot"], capacityInUse: data / 20),
        ]
        let used = volumes.reduce(0) { $0 + $1.capacityInUse }
        let free = data / 3
        let container = APFSContainer(reference: "demo", capacity: used + free, free: free, volumes: volumes)
        return VolumeInventory(container: container, available: free, availableForImportantUsage: free + data / 50)
    }
}

/// The folders the Library indexes.
enum LibraryFolders {
    static let standard = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]

    /// Folders the user added in Settings.
    static var added: [String] {
        get { UserDefaults.standard.stringArray(forKey: "libraryFolders") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "libraryFolders") }
    }

    /// Folders the user left out of the Library (a game project's assets, say): the index skips them.
    static var leftOut: [String] {
        get { UserDefaults.standard.stringArray(forKey: "libraryLeftOut") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "libraryLeftOut") }
    }
}
