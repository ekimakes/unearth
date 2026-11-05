#if DEBUG
import AppKit
import SwiftUI
import UnearthCore

/// `--snapshot-dir <dir>`: after the scan, renders every screen to PNG (light and dark), then quits.
/// SwiftUI renders the views itself, so no screen-recording permission is involved.
@MainActor
enum DebugSnapshots {
    static let size = CGSize(width: 960, height: 900)

    static func run(_ model: AppModel, directory: String) async {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if model.options.timelineCheck {
            await checkTimeline(model, directory: directory)
            NSApp.terminate(nil)
            return
        }
        if model.options.overviewCheck {
            await checkOverview(model, directory: directory)
            NSApp.terminate(nil)
            return
        }
        if model.options.trashCheck {
            await checkTrash(model, directory: directory)
            NSApp.terminate(nil)
            return
        }
        if model.options.openCheck {
            await checkOpening(model, directory: directory)
            NSApp.terminate(nil)
            return
        }
        if model.options.removalCheck {
            await checkRemoval(model, directory: directory)
            NSApp.terminate(nil)
            return
        }
        if model.options.scanRoot != nil {
            // The demo disk's files are small and new, so loosen the Large & Old Files filters (not saved).
            model.settings.largeFileThreshold = 50_000_000
            model.settings.oldFileAgeDays = 0
            await model.replan()
        }
        // The Library starts after the scan; wait for its first pass and for its images to be read (a demo
        // library takes seconds), then for the collections, which need the photos' prints.
        let deadline = ContinuousClock.now + .seconds(240)
        while model.library.status != .ready, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if model.options.scanRoot != nil {
            // Demo files are small and new: loosen the collections' thresholds too (not saved).
            model.collections.settings.bigVideoBytes = 1_000_000
            model.collections.settings.bigVideoDays = 0
            model.collections.settings.duplicateMinBytes = 10_000
        }
        model.refreshCollections()
        await model.collections.waitUntilLooked()
        let items = SidebarItem.snapshotItems + [.place(Paths.join(model.realPath(model.homePath), "Downloads"))]
        var files: [SidebarItem: [IndexedFile]] = [:]
        for item in items {
            let scope: BrowseScope? = switch item {
            case .recents: .recents
            case .kind(let kind): .kind(kind)
            default: nil
            }
            if let scope {
                files[item] = await model.library.files(matching: BrowseFilters().query(for: scope), sort: .added,
                                                        limit: LibraryModel.pageSize, offset: 0)
            }
            if case .place(let path) = item { files[item] = PlaceListing.list(path, sizes: model.folderSize).entries }
        }
        await loadThumbnails(model, files.values.flatMap { $0 })
        var timelines: [SidebarItem: Timeline] = [:]
        for case .kind(let kind) in items {
            timelines[.kind(kind)] = await timeline(of: .kind(kind), model: model)
        }
        for scheme in [ColorScheme.light, .dark] {
            render(SidebarSnapshot(), model: model, scheme: scheme, height: 980,
                   to: URL(fileURLWithPath: directory).appendingPathComponent("sidebar-\(scheme == .light ? "light" : "dark").png"))
            render(DesignSamples(), model: model, scheme: scheme, height: 760,
                   to: URL(fileURLWithPath: directory).appendingPathComponent("design-\(scheme == .light ? "light" : "dark").png"))
        }
        for item in items {
            model.sidebarSelection = item
            try? await Task.sleep(for: .milliseconds(300))
            for scheme in [ColorScheme.light, .dark] {
                render(content(for: item, model: model, files: files[item] ?? [], timeline: timelines[item]), model: model, scheme: scheme,
                       height: item == .home ? 1_800 : item == .recents ? 1_300 : nil,
                       to: URL(fileURLWithPath: directory).appendingPathComponent("\(item.snapshotName)-\(scheme == .light ? "light" : "dark").png"))
            }
        }
        await renderTimelines(model, images: timelines[.kind(.image)], directory: directory)
        // Search, once the demo's images have been read.
        let reading = ContinuousClock.now + .seconds(120)
        while model.library.status != .ready, ContinuousClock.now < reading {
            try? await Task.sleep(for: .milliseconds(250))
        }
        for text in ["invoice", "screenshots with invoice", "receipt total", "images from last week", "pdfs from the last month"] {
            let query = SearchQuery.parse(text, now: Date())
            let hits = await model.library.search(query)
            await loadThumbnails(model, hits.map(\.file))
            let name = "search-" + text.replacingOccurrences(of: " ", with: "-")
            for scheme in [ColorScheme.light, .dark] {
                render(SearchResultsContent(query: query, hits: hits, selection: .constant([]), trashing: .constant([])),
                       model: model, scheme: scheme, height: 640,
                       to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(scheme == .light ? "light" : "dark").png"))
            }
        }
        // Demo disk only: a file deleted behind the Library's back, then opened from it.
        if model.options.scanRoot != nil {
            let downloads = Paths.join(model.realPath(model.homePath), "Downloads")
            let stale = Paths.join(downloads, "Stale check.txt")
            FileManager.default.createFile(atPath: stale, contents: Data("stale".utf8))
            await model.library.refreshAndWait([downloads])
            var query = SearchQuery()
            query.text = "stale check"
            if let file = await model.library.search(query).first?.file {
                try? FileManager.default.removeItem(atPath: stale)
                model.open([file])
                for scheme in [ColorScheme.light, .dark] {
                    render(FailureBanner(failures: model.lastFailures).padding(24), model: model, scheme: scheme, height: 180,
                           to: URL(fileURLWithPath: directory).appendingPathComponent("stale-banner-\(scheme == .light ? "light" : "dark").png"))
                }
                try? await Task.sleep(for: .seconds(1))
                let after = await model.library.search(query)
                try? "found before: 1, after: \(after.count)\n".write(
                    toFile: Paths.join(directory, "stale-check.txt"), atomically: true, encoding: .utf8)
            }
            model.lastFailures = []
        }
        // Demo disk only: leaving a folder out of the Library takes its files out of it, and putting it back
        // brings them back.
        if model.options.scanRoot != nil {
            let music = Paths.join(model.realPath(model.homePath), "Music")
            let before = model.library.count(of: .audio)
            await model.setLeftOutFolders([music])
            let without = model.library.count(of: .audio)
            await model.setLeftOutFolders([])
            let after = model.library.count(of: .audio)
            try? "audio files: \(before), with Music left out: \(without), with it back: \(after)\n"
                .write(toFile: Paths.join(directory, "leave-out-check.txt"), atomically: true, encoding: .utf8)
        }
        // Only ever in a dry run: Move to Trash from Duplicates, and uninstalling the demo's unused app.
        if model.options.dryRun, model.options.scanRoot != nil {
            let groups = model.collections.duplicates
            let extras = groups.flatMap { $0.trashable($0.defaultSelection(), exists: { FileManager.default.fileExists(atPath: $0) }) }
            if !extras.isEmpty {
                await model.trash(collection: .duplicates, files: extras)
                if let outcome = model.lastOutcome {
                    for scheme in [ColorScheme.light, .dark] {
                        render(CleanupResultBanner(outcome: outcome).padding(24), model: model, scheme: scheme, height: 160,
                               to: URL(fileURLWithPath: directory).appendingPathComponent("duplicates-trash-banner-\(scheme == .light ? "light" : "dark").png"))
                    }
                }
            }
            if let app = model.collections.apps.first(where: { $0.vendorFolder == nil }) {
                await model.uninstall(app)
                for scheme in [ColorScheme.light, .dark] {
                    if let outcome = model.lastOutcome {
                        render(CleanupResultBanner(outcome: outcome).padding(24), model: model, scheme: scheme, height: 160,
                               to: URL(fileURLWithPath: directory).appendingPathComponent("uninstall-banner-\(scheme == .light ? "light" : "dark").png"))
                    }
                }
                let stillThere = ([app.path] + app.leftovers.map(\.path)).allSatisfy { FileManager.default.fileExists(atPath: $0) }
                let skipped = model.lastFailures.map { "  \($0.title) (\($0.path ?? "")): \($0.reason)" }.joined(separator: "\n")
                try? "duplicates trashed (dry run): \(extras.count), uninstall entries: \(model.lastOutcome?.entries.count ?? 0), everything still there: \(stillThere)\nskipped:\n\(skipped)\n"
                    .write(toFile: Paths.join(directory, "dry-run-check.txt"), atomically: true, encoding: .utf8)
            }
            model.lastOutcome = nil
            model.lastFailures = []
        }
        // Only ever with --dry-run: Move to Trash from a browse screen, then the banner it leaves.
        if model.options.dryRun, let images = files[.kind(.image)], images.count >= 2 {
            await model.moveFilesToTrash(Array(images.prefix(2)))
            if let outcome = model.lastOutcome {
                for scheme in [ColorScheme.light, .dark] {
                    render(CleanupResultBanner(outcome: outcome).padding(24), model: model, scheme: scheme, height: 160,
                           to: URL(fileURLWithPath: directory).appendingPathComponent("browse-trash-banner-\(scheme == .light ? "light" : "dark").png"))
                }
            }
        }
        if model.options.showOnboarding {
            let pages: [(String, AnyView)] = [
                ("onboarding-1", AnyView(WelcomePage {}.frame(width: 560))),
                ("onboarding-2", AnyView(AccessPage {}.frame(width: 560))),
                ("settings-privacy", AnyView(PrivacySettings().frame(width: 520, height: 300))),
                ("settings-library", AnyView(LibrarySettings().frame(width: 540, height: 520))),
                ("settings-cleanup", AnyView(CleanUpSettings().frame(width: 540, height: 460))),
                ("settings-never-touch", AnyView(NeverTouchSettings().frame(width: 520, height: 300))),
            ]
            for (name, page) in pages {
                for scheme in [ColorScheme.light, .dark] {
                    render(page, model: model, scheme: scheme,
                           to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(scheme == .light ? "light" : "dark").png"))
                }
            }
        }
        // Only ever with --dry-run: a debug run must never move real files.
        if model.options.autoCleanDefault, model.options.dryRun, let plan = model.plan {
            await model.moveToTrash(plan.defaultSelection())
            if let outcome = model.lastOutcome {
                for scheme in [ColorScheme.light, .dark] {
                    render(CleanupResultBanner(outcome: outcome).padding(24), model: model, scheme: scheme,
                           to: URL(fileURLWithPath: directory).appendingPathComponent("banner-\(scheme == .light ? "light" : "dark").png"))
                }
            }
        }
        NSApp.terminate(nil)
    }

    /// Each screen's content without its scroll view.
    @ViewBuilder
    static func content(for item: SidebarItem, model: AppModel, files: [IndexedFile], timeline: Timeline?) -> some View {
        switch item {
        case .home:
            HomeContent(onReview: {})
        case .storage:
            StorageContent(onReview: {})
        case .junk:
            CleanupSectionContent(section: .junk)
        case .developer:
            CleanupSectionContent(section: .developer)
        case .largeFiles:
            CleanupSectionContent(section: .largeFiles)
        case .systemData:
            SystemDataContent()
        case .diskMap:
            if let tree = model.tree {
                DiskMapContent(tree: tree, state: .constant(Self.mapState(focusedOn: model.homePath, in: tree)))
            }
        case .recents:
            flatBrowse(.recents, files: files, selection: [])
        case .kind(let kind):
            if let timeline {
                // The second file shows the selected look.
                TimelineSnapshot(scope: .kind(kind), timeline: timeline, grouping: .date, zoom: .all,
                                 selection: Set([timeline.file(at: .init(section: 0, item: 1))?.id].compactMap { $0 }))
            }
        case .source(let source):
            flatBrowse(.source(source), files: files, selection: [])
        case .downloadedFrom:
            SourcesContent()
        case .place(let path):
            VStack(alignment: .leading, spacing: 0) {
                PlacesBreadcrumb(root: path, folder: .constant(path))
                    .padding(.horizontal, TimelineMetrics.padding)
                    .padding(.top, 22)
                    .padding(.bottom, 8)
                PlacesContent(folder: .constant(path), listing: PlaceListing.list(path, sizes: model.folderSize),
                              selection: .constant([]), trashing: .constant([]))
            }
        case .cleanUp:
            CleanUpContent(onReview: {})
        case .collection(let kind):
            let groups = model.collections.duplicates
            CollectionReviewContent(
                kind: kind, tab: .constant(kind == .lookAlikes ? .lookAlikes : .copies), groups: .constant(groups),
                selection: .constant(groups.reduce(into: Set<Int64>()) { $0.formUnion($1.defaultSelection()) }),
                lookAlikeSelection: .constant([]), uninstalling: .constant(nil), trashing: .constant([]))
        }
    }

    private static func flatBrowse(_ scope: BrowseScope, files: [IndexedFile], selection: Set<Int64>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            BrowseBar(scope: scope, filters: .constant(BrowseFilters()))
            BrowseContent(scope: scope, files: files, filters: BrowseFilters(), selection: .constant(selection), trashing: .constant([]))
        }
    }

    /// A screen's timeline with the files of its first screenful loaded and their thumbnails made.
    private static func timeline(of scope: BrowseScope, model: AppModel, grouping: FileGrouping = .date) async -> Timeline {
        let timeline = Timeline()
        let query = BrowseFilters().query(for: scope)
        await timeline.load(.library(model.library, query: query, grouping: grouping, sort: .made), keepingPages: false)
        let metrics = TimelineSnapshot.metrics(scope: scope, grouping: grouping)
        await loadWindow(timeline, metrics: metrics, window: 0..<Double(TimelineSnapshot.viewport))
        return timeline
    }

    private static func loadWindow(_ timeline: Timeline, metrics: TimelineMetrics, window: Range<Double>) async {
        let layout = metrics.layout(timeline.counts)
        await timeline.loadVisible(layout, window: window)
        for placed in layout.lines(in: window) {
            guard case .row(let section, let row) = placed.line else { continue }
            for item in (row * layout.columns)..<((row + 1) * layout.columns) {
                guard let file = timeline.file(at: .init(section: section, item: item)) else { continue }
                _ = await ThumbnailCache.shared.image(for: file.path, side: metrics.thumbnailSide)
            }
        }
    }

    /// For a big library: once its first pass is done (images are still being read, as for someone using the app),
    /// renders the timeline's pages, then drives the real one in the window.
    private static func checkTimeline(_ model: AppModel, directory: String) async {
        let deadline = ContinuousClock.now + .seconds(900)
        while model.library.isIndexing || model.library.status == .idle, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        // On the real disk it's numbers only: no pictures of someone's files are written anywhere.
        if model.options.scanRoot != nil {
            await renderTimelines(model, images: await timeline(of: .kind(.image), model: model), directory: directory)
        }
        await driveTimeline(model, directory: directory)
    }

    /// Ticks folder tiles with real clicks: several add up, a tick never opens a folder, and once anything is
    /// selected a click on a tile ticks it. Run with `-browseGrouping.image folder`.
    private static func checkOverview(_ model: AppModel, directory: String) async {
        func wait(_ what: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(60)
            while !what(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        }
        await wait { !model.library.isIndexing && model.library.status != .idle }
        model.sidebarSelection = .kind(.image)
        await wait { TimelineProbe.setZoom != nil && TimelineProbe.zoom != nil }
        try? await Task.sleep(for: .seconds(1))
        TimelineProbe.setZoom?(.overview)
        await wait { TimelineProbe.tiles.count >= 3 && TimelineProbe.overviewTimeline != nil }
        try? await Task.sleep(for: .seconds(1))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }), let content = window.contentView,
              let timeline = TimelineProbe.overviewTimeline, let selection = TimelineProbe.overviewSelection,
              let zoom = TimelineProbe.zoom, timeline.sections.count >= 3 else {
            try? "couldn't reach the overview\n".write(toFile: Paths.join(directory, "overview-check.txt"), atomically: true, encoding: .utf8)
            return
        }
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)

        func click(_ x: CGFloat, _ y: CGFloat) async {
            let point = NSPoint(x: x, y: content.frame.height - y)
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            // The release goes in the queue first: the press can start a loop that waits for it.
            if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
            if let down = event(.leftMouseDown) { window.sendEvent(down) }
            try? await Task.sleep(for: .milliseconds(600))
        }
        // Hovering is what shows the tick on a fresh tile; a real pointer gets there first.
        func move(_ x: CGFloat, _ y: CGFloat) async {
            let point = NSPoint(x: x, y: content.frame.height - y)
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                window.sendEvent(event)
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        func corner(_ tile: Int) -> CGPoint {
            let frame = TimelineProbe.tiles[tile] ?? .zero
            return CGPoint(x: frame.minX + 18, y: frame.minY + 18)
        }
        func middle(_ tile: Int) -> CGPoint {
            let frame = TimelineProbe.tiles[tile] ?? .zero
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        func count(_ tiles: [Int]) -> Int { tiles.reduce(0) { $0 + timeline.sections[$1].count } }
        var report = "tiles: \(timeline.sections.count), counts \(timeline.sections.prefix(3).map(\.count))\n"
        func expect(_ name: String, _ tiles: [Int], open: Bool = false) {
            let got = selection().count, wanted = count(tiles), opened = zoom() != .overview
            report += "\(name): \(got == wanted && opened == open ? "right" : "WRONG") (\(got) selected, wanted \(wanted), zoom \(zoom()))\n"
        }

        // Nothing ticked yet, so ticks show only under the pointer.
        await move(corner(0).x, corner(0).y)
        await click(corner(0).x, corner(0).y)
        expect("first tick", [0])
        await click(corner(1).x, corner(1).y)
        expect("second tick adds", [0, 1])
        await click(middle(2).x, middle(2).y)
        expect("a click on a tile while selecting ticks it", [0, 1, 2])
        report += "whole tiles: \(timeline.wholeSections(in: selection()))\n"
        await click(corner(1).x, corner(1).y)
        expect("ticking again takes it out", [0, 2])
        await click(middle(0).x, middle(0).y)
        expect("so does a click on a ticked tile", [2])
        TimelineProbe.clearOverviewSelection?()
        try? await Task.sleep(for: .milliseconds(400))
        expect("Deselect clears it", [])
        await click(middle(1).x, middle(1).y)
        expect("with nothing selected a click opens the folder", [], open: true)
        try? report.write(toFile: Paths.join(directory, "overview-check.txt"), atomically: true, encoding: .utf8)
    }

    /// How soon after launch the screens filled in. Numbers only.
    private static func checkOpening(_ model: AppModel, directory: String) async {
        func sinceLaunch() -> String {
            String(format: "%.2f s", NSRunningApplication.current.launchDate.map { Date().timeIntervalSince($0) } ?? 0)
        }
        var report = "library tiles \(model.library.kinds.count) kinds, storage numbers and plan: \(sinceLaunch()), plan items \(model.plan?.items.count ?? 0), safe to free \(ByteFormatting.string(model.safeToFree))\n"
        report += "scan blocking the app \(model.isScanning), scan behind the scenes \(model.isRefreshing)\n"
        let clock = ContinuousClock()
        let limit = clock.now + .seconds(120)
        while model.collections.summaries.isEmpty, clock.now < limit { try? await Task.sleep(for: .milliseconds(20)) }
        report += "first collection piles: \(sinceLaunch()), \(model.collections.summaries.count) piles\n"
        while !model.collections.hasLooked, clock.now < limit { try? await Task.sleep(for: .milliseconds(50)) }
        report += "every pile looked at: \(sinceLaunch()), \(model.collections.summaries.count) piles\n"
        try? report.write(toFile: Paths.join(directory, "open-check.txt"), atomically: true, encoding: .utf8)
    }

    /// A real move to the Trash and back, the way the confirmation's button starts one, with the screen open on the
    /// files. Only on a sample disk on a volume of its own, so nothing reaches the real Trash.
    private static func checkTrash(_ model: AppModel, directory: String) async {
        var report = ""
        func note(_ line: String) {
            report += line + "\n"
            try? report.write(toFile: Paths.join(directory, "trash-check.txt"), atomically: true, encoding: .utf8)
        }
        func device(_ path: String) -> dev_t? {
            var info = stat()
            return lstat(path, &info) == 0 ? info.st_dev : nil
        }
        guard let root = model.options.scanRoot, !model.options.dryRun, let disk = device(root), disk != device(NSHomeDirectory()),
              let volume = (try? URL(fileURLWithPath: root).resourceValues(forKeys: [.volumeURLKey]))?.volume?.path else {
            note("Refused: only on a sample disk on a volume of its own, outside safe mode.")
            return
        }
        let clock = ContinuousClock()
        func waitUntil(_ limit: Duration, _ done: () -> Bool) async {
            let end = clock.now + limit
            while !done(), clock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        }
        func present(_ files: [IndexedFile]) -> Int { files.filter { FileManager.default.fileExists(atPath: $0.path) }.count }

        let opened = NSRunningApplication.current.launchDate.map { Date().timeIntervalSince($0) } ?? 0
        note("numbers on screen \(String(format: "%.2f", opened)) s after launch, last scan used \(model.tree?.id != nil && model.isScanning == false), checking behind the scenes \(model.isRefreshing)")
        await waitUntil(.seconds(300)) { !model.library.isIndexing && model.library.status != .idle }
        TimelineProbe.opensEveryFile = true
        model.sidebarSelection = .kind(.image)
        await waitUntil(.seconds(30)) { (TimelineProbe.layout?.height ?? 0) > (TimelineProbe.tracker?.viewport ?? 0) }
        guard let timeline = TimelineProbe.timeline else {
            note("The timeline never appeared.")
            return
        }
        let all = await timeline.allFiles()
        note("\(all.count) images on screen")

        let confirmed = clock.now
        Task { await model.moveFilesToTrash(all) }
        var banner: Duration?
        var furthest = 0
        await waitUntil(.seconds(180)) {
            if let progress = model.trashProgress {
                banner = banner ?? clock.now - confirmed
                furthest = max(furthest, progress.done)
            }
            return model.lastOutcome != nil
        }
        guard let outcome = model.lastOutcome else {
            note("The move never finished.")
            return
        }
        let moved = outcome.entries.filter { $0.state == .inTrash }.count
        note("progress banner after \(banner.map { "\($0)" } ?? "never"), reached \(furthest), finished after \(clock.now - confirmed)")
        note("moved \(moved), skipped \(outcome.failures.count)")
        if let failure = outcome.failures.first { report += "first skipped: \(failure.reason)\n" }
        note("still at their old paths: \(present(all)) of \(all.count)")
        report += "in the volume's Trash: \((try? FileManager.default.contentsOfDirectory(atPath: Paths.join(volume, ".Trashes/\(getuid())")))?.count ?? -1)\n"
        var blocked = false
        var quiet = false
        await waitUntil(.seconds(5)) {
            blocked = blocked || model.isScanning
            quiet = quiet || model.isRefreshing
            return quiet
        }
        await waitUntil(.seconds(30)) { timeline.count <= all.count - moved }
        note("images on screen \(clock.now - confirmed) after the click: \(timeline.count)")
        await waitUntil(.seconds(300)) {
            blocked = blocked || model.isScanning
            return !model.isRefreshing
        }
        note("the scan after the move ran behind the scenes \(quiet), held anything up \(blocked)")
        note("history says in Trash: \(model.history.filter { $0.state == .inTrash }.count)")

        await model.undoLastCleanup()
        note("after Undo: \(present(all)) of \(all.count) back")
        try? await Task.sleep(for: .seconds(2))
        await waitUntil(.seconds(300)) { !model.isRefreshing }
        await waitUntil(.seconds(30)) { timeline.count == all.count }
        note("images on screen after Undo: \(timeline.count)")

        // One file of this check's own into the real Trash and straight back: the same call, with this app's permissions.
        let probe = URL(fileURLWithPath: directory).appendingPathComponent("unearth-trash-probe-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data("probe".utf8)) else { return }
        defer { try? FileManager.default.removeItem(at: probe) }
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: probe, resultingItemURL: &trashed)
            guard let trashed = trashed as URL? else { return note("real Trash: no location came back") }
            try FileManager.default.moveItem(at: trashed, to: probe)
            note("real Trash: went to \(trashed.deletingLastPathComponent().lastPathComponent) and came back")
        } catch {
            note("real Trash: \(error.localizedDescription)")
        }
    }

    /// Moves things to the Trash with their page open, the way the confirmation's button does, writing how long they
    /// stayed listed and saving the window at each step; then Undo. Only on a sample disk on a volume of its own, so
    /// nothing reaches the real Trash.
    private static func checkRemoval(_ model: AppModel, directory: String) async {
        var report = ""
        func note(_ line: String) {
            report += line + "\n"
            try? report.write(toFile: Paths.join(directory, "removal-check.txt"), atomically: true, encoding: .utf8)
        }
        func device(_ path: String) -> dev_t? {
            var info = stat()
            return lstat(path, &info) == 0 ? info.st_dev : nil
        }
        guard let root = model.options.scanRoot, !model.options.dryRun, let disk = device(root), disk != device(NSHomeDirectory()) else {
            note("Refused: only on a sample disk on a volume of its own, outside safe mode.")
            return
        }
        let clock = ContinuousClock()
        func waitUntil(_ limit: Duration, _ done: () -> Bool) async {
            let end = clock.now + limit
            while !done(), clock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        }
        func picture(_ name: String) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }), let view = window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: Paths.join(directory, name + ".png")))
        }

        await waitUntil(.seconds(240)) { model.library.status == .ready }
        model.collections.settings.bigVideoBytes = 1_000_000
        model.collections.settings.bigVideoDays = 0
        model.collections.settings.duplicateMinBytes = 10_000
        model.refreshCollections()
        await model.collections.waitUntilLooked()

        /// Waits out the scan and the look that follow a move.
        func settle() async {
            await waitUntil(.seconds(60)) { !model.isScanning && !model.isRefreshing }
            await model.collections.waitUntilLooked()
        }
        /// Runs `move`, then writes how much was still listed at its result, how soon nothing was, and the message.
        func timed(_ name: String, _ move: @escaping @MainActor () async -> Void, listed: () -> Int) async {
            let before = listed()
            model.lastOutcome = nil
            let start = clock.now
            Task { await move() }
            await waitUntil(.seconds(30)) { model.lastOutcome != nil }
            let atResult = listed()
            await waitUntil(.seconds(30)) { listed() == 0 }
            note("\(name): \(before) listed, \(atResult) at the result, none after \(clock.now - start). Says: \(model.lastRemoved ?? "nothing")")
        }
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

        model.sidebarSelection = .collection(.duplicates)
        try? await Task.sleep(for: .seconds(1))
        picture("duplicates-1-before")
        let groups = model.collections.duplicates
        let picked = groups.flatMap { $0.trashable($0.defaultSelection(), exists: exists) }
        let paths = Set(picked.map(\.path))
        func listed() -> Int { model.collections.duplicates.flatMap(\.files).filter { paths.contains($0.path) }.count }
        note("Duplicates: \(groups.count) groups on the page: \(TimelineProbe.duplicateGroupsOnPage)")
        await timed("Duplicates", { await model.trash(collection: .duplicates, files: picked) }, listed: listed)
        try? await Task.sleep(for: .milliseconds(200))
        picture("duplicates-2-gone")
        note("groups on the page: \(TimelineProbe.duplicateGroupsOnPage), the card says \(model.collections.summaries[.duplicates]?.count ?? -1)")

        let undone = clock.now
        await model.undoLastCleanup()
        note("Undo: \(listed()) of \(picked.count) back once it returned, after \(clock.now - undone)")
        await waitUntil(.seconds(60)) { TimelineProbe.duplicateGroupsOnPage == groups.count }
        note("groups on the page \(clock.now - undone) after Undo: \(TimelineProbe.duplicateGroupsOnPage)")
        picture("duplicates-3-undone")
        await settle()
        note("Undo settled: \(model.collections.duplicates.count) groups, \(listed()) of \(picked.count) listed")

        // A look-alike, with the page open.
        model.sidebarSelection = .collection(.lookAlikes)
        try? await Task.sleep(for: .milliseconds(300))
        if let photo = model.collections.lookAlikes.first?.files.last {
            await timed("Look-alikes", { await model.trash(collection: .lookAlikes, files: [photo]) }, listed: {
                model.collections.lookAlikes.flatMap(\.files).filter { $0.path == photo.path }.count
            })
        } else {
            note("Look-alikes: none found")
        }
        await settle()

        // A list, two at once.
        model.sidebarSelection = .collection(.oldScreenshots)
        try? await Task.sleep(for: .milliseconds(300))
        let shots = model.collections.files[.oldScreenshots] ?? []
        if !shots.isEmpty {
            await timed("Old screenshots", { await model.trash(collection: .oldScreenshots, files: shots) }, listed: {
                (model.collections.files[.oldScreenshots] ?? []).count
            })
            note("its card says \(model.collections.summaries[.oldScreenshots]?.count ?? -1)")
        } else {
            note("Old screenshots: none found")
        }
        await settle()

        // A picture from the Library, with its timeline on screen.
        TimelineProbe.opensEveryFile = true
        model.sidebarSelection = .kind(.image)
        await waitUntil(.seconds(30)) { TimelineProbe.timeline?.count ?? 0 > 0 }
        if let timeline = TimelineProbe.timeline, let image = await timeline.allFiles().last {
            let before = timeline.count
            await timed("Timeline", { await model.moveFilesToTrash([image]) }, listed: { timeline.count > before - 1 ? 1 : 0 })
        }
        await settle()

        // A folder from the Disk Map, then one after a running scan went past it: holding the finished scan back makes
        // that certain.
        model.sidebarSelection = .diskMap
        try? await Task.sleep(for: .milliseconds(300))
        func folder(_ path: String) -> CleanupItem {
            .picked(path: path, bytes: model.tree?.node(atPath: path)?.totalBytes ?? 0, what: "A folder from the check.")
        }
        let (first, second) = ("/Users/demo/Pictures/Beach", "/Users/demo/Documents/Thesis")
        await timed("Disk Map folder", { await model.moveToTrash([folder(first)]) }, listed: {
            model.tree?.node(atPath: first) == nil ? 0 : 1
        })
        await settle()
        TimelineProbe.holdsScans = true
        Task { await model.startScan() }
        await waitUntil(.seconds(30)) { TimelineProbe.heldScan != nil }
        await timed("Folder behind a running scan", { await model.moveToTrash([folder(second)]) }, listed: {
            model.tree?.node(atPath: second) == nil ? 0 : 1
        })
        TimelineProbe.holdsScans = false
        TimelineProbe.heldScan?.resume()
        TimelineProbe.heldScan = nil
        var cameBack = false
        await waitUntil(.seconds(3)) {
            cameBack = cameBack || model.tree?.node(atPath: first) != nil || model.tree?.node(atPath: second) != nil
            return false
        }
        note("came back when the scan finished: \(cameBack)")
        await settle()
        note("left in the Library under them: \(await model.library.search(SearchQuery.parse("Beach", now: Date())).count)")
        let (beach, music) = (exists(Paths.join(root, String(first.dropFirst()))), exists(Paths.join(root, String(second.dropFirst()))))
        note("on disk afterwards: \(beach), \(music)")

        // An app, with what it keeps.
        model.sidebarSelection = .collection(.unusedApps)
        try? await Task.sleep(for: .milliseconds(300))
        if let app = model.collections.apps.first(where: { $0.vendorFolder == nil && !$0.isApple }) {
            await timed("Unused app", { await model.uninstall(app) }, listed: {
                model.collections.apps.filter { $0.path == app.path }.count
            })
        } else {
            note("Unused app: none found")
        }
        await settle()
        note("failures left: \(model.lastFailures.map(\.reason))")
    }

    /// Jumps through the timeline on screen and sweeps down all of it, writing down where it landed, how soon the
    /// files in view had arrived and how long the main thread was held up.
    private static func driveTimeline(_ model: AppModel, directory: String) async {
        TimelineProbe.opensEveryFile = true
        model.sidebarSelection = .kind(.image)
        let clock = ContinuousClock()
        let opening = clock.now
        let appearing = clock.now + .seconds(30)
        while clock.now < appearing, (TimelineProbe.layout?.height ?? 0) <= (TimelineProbe.tracker?.viewport ?? 0) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        var report = "opened in \(clock.now - opening)"
        if let opened = TimelineProbe.opened { report += ", by itself as \(opened.grouping) at \(opened.zoom)" }
        report += "\n"
        defer { try? report.write(toFile: Paths.join(directory, "timeline-live.txt"), atomically: true, encoding: .utf8) }
        guard let tracker = TimelineProbe.tracker, let layout = TimelineProbe.layout, let timeline = TimelineProbe.timeline,
              let scrollTo = TimelineProbe.scrollTo, layout.height > tracker.viewport else {
            report += "The timeline never appeared in the window.\n"
            return
        }
        report += "viewport \(Int(tracker.viewport)), height \(Int(layout.height)), \(layout.columns) across, "
        report += "\(timeline.count) files in \(layout.counts.count) sections\n"

        func inView() -> (shown: Int, loaded: Int) {
            var (shown, loaded) = (0, 0)
            for placed in layout.lines(in: tracker.offset..<(tracker.offset + tracker.viewport)) {
                guard case .row(let section, let row) = placed.line else { continue }
                let start = row * layout.columns
                for item in start..<min(start + layout.columns, layout.counts[section]) {
                    shown += 1
                    if timeline.file(at: .init(section: section, item: item)) != nil { loaded += 1 }
                }
            }
            return (shown, loaded)
        }
        func land(_ target: Double) async -> String {
            let start = clock.now
            scrollTo(target)
            var arrived: Duration?
            let limit = clock.now + .seconds(3)
            while clock.now < limit {
                try? await Task.sleep(for: .milliseconds(5))
                let (shown, loaded) = inView()
                if abs(tracker.offset - target) < 1, shown > 0, loaded == shown {
                    arrived = clock.now - start
                    break
                }
            }
            let (shown, loaded) = inView()
            let title = tracker.pinned.map { timeline.sections[$0.section].key.title(calendar: timeline.calendar) } ?? "none"
            let time = arrived.map { "\($0)" } ?? "not within 3 s"
            return "to \(Int(target)): landed at \(Int(tracker.offset)), \(loaded) of \(shown) files in view after \(time), pinned \(title)\n"
        }

        report += "\nJumps\n"
        let scrollable = layout.height - tracker.viewport
        for fraction in [0.25, 0.5, 0.75, 1, 0.1, 0] { report += await land(fraction * scrollable) }

        report += "\nMonths\n"
        let count = layout.starts.count
        for section in [count / 4, count / 2, count - 2] where section >= 0 {
            report += await land(min(layout.starts[section], scrollable))
            report += "  wanted \(timeline.sections[section].key.title(calendar: timeline.calendar))\n"
        }

        // Real wheel events go through AppKit as a person's would, so the scroll view moves on its own.
        func wheel(_ points: Int32, at x: CGFloat, _ y: CGFloat) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }),
                  let screen = window.screen,
                  let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -points, wheel2: 0, wheel3: 0)
            else { return }
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            let inScreen = window.convertPoint(toScreen: NSPoint(x: x, y: y))
            cgEvent.location = CGPoint(x: inScreen.x, y: screen.frame.maxY - inScreen.y)
            if let event = NSEvent(cgEvent: cgEvent) { window.sendEvent(event) }
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) else {
            report += "no window\n"
            return
        }
        report += "\nScroll wheel\n"
        let (width, height) = (window.frame.width, window.contentView?.frame.height ?? window.frame.height)
        let spots: [(String, CGFloat, CGFloat)] = [
            ("over the pictures", width * 0.6, height * 0.4), ("over the pinned header", width * 0.6, tracker.viewport - 20),
            ("over the pictures again", width * 0.6, height * 0.4), ("over the rail", width - 24, height * 0.4),
        ]
        for (name, x, y) in spots {
            _ = await land(scrollable / 3)
            try? await Task.sleep(for: .milliseconds(300))
            var chain: [String] = []
            var view = window.contentView?.superview?.hitTest(NSPoint(x: x, y: y))
            while let found = view, chain.count < 5 {
                chain.append(String(describing: type(of: found)))
                view = found.superview
            }
            report += "\(name) at (\(Int(x)), \(Int(y))) hits \(chain.joined(separator: " < "))\n"
            let before = tracker.offset
            for _ in 0..<10 {
                // An app-wide monitor catches the wheel over these two; `sendEvent` goes past those, so it's called here.
                if name == "over the rail" || name == "over the pinned header" {
                    _ = TimelineProbe.overlayWheel?(NSPoint(x: x, y: y), height, -40)
                } else {
                    wheel(40, at: x, y)
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
            try? await Task.sleep(for: .milliseconds(200))
            report += "\(name): moved \(Int(tracker.offset - before)) points for 400\n"
        }

        // A flick, 4,000 points a second as fast as a trackpad throws it, for 8 seconds; then the rail dragged from
        // top to bottom, every step a different screenful.
        func run(_ name: String, steps: Int, step move: (Int) -> Void) async {
            var worst = Duration.zero
            var worstStep = 0
            var late = 0
            let began = clock.now
            let from = tracker.offset
            for step in 0...steps {
                move(step)
                let before = clock.now
                try? await Task.sleep(for: .milliseconds(16))
                let over = clock.now - before - .milliseconds(16)
                if over > worst { (worst, worstStep) = (over, step) }
                if over > .milliseconds(16) { late += 1 }
            }
            report += "\(name): \(steps) steps in \(clock.now - began), \(Int(tracker.offset - from)) points, "
            report += "worst step \(worst) over its 16 ms at step \(worstStep), \(late) a frame late, memory \(footprint() / 1_000_000) MB\n"
        }
        report += "\nScrolling\n"
        _ = await land(0)
        try? "".write(toFile: Paths.join(directory, "sweeping"), atomically: true, encoding: .utf8)
        await run("flick", steps: 480) { _ in wheel(66, at: width * 0.6, height * 0.4) }
        try? "".write(toFile: Paths.join(directory, "flicked"), atomically: true, encoding: .utf8)
        await run("rail", steps: 600) { scrollTo(Double($0) / 600 * scrollable) }
        report += await land(scrollable / 2)

        report += "\nSelecting\n"
        let month = count / 2
        var started = clock.now
        let files = await timeline.files(in: month)
        report += "a month: \(files.count) of \(layout.counts[month]) in \(clock.now - started)\n"
        started = clock.now
        let everything = await timeline.allFiles()
        report += "everything: \(everything.count) of \(timeline.count) in \(clock.now - started)\n"
        // Clicks and keys only on the demo disk: on the real one nothing takes the keyboard from whoever's at the Mac.
        if model.options.scanRoot != nil { await clickAndType(model, report: &report, land: land) }
        report += "\nMemory footprint: \(footprint() / 1_000_000) MB\n"
        await driveFolder(model, report: &report)
    }

    /// A big folder in Places: it opens as a timeline with its subfolders on top, from the listing rather than the index.
    private static func driveFolder(_ model: AppModel, report: inout String) async {
        let folder = Paths.join(model.realPath(model.homePath), "Downloads")
        let images = TimelineProbe.timeline
        model.sidebarSelection = .place(folder)
        let clock = ContinuousClock()
        let opened = clock.now
        let limit = clock.now + .seconds(30)
        while clock.now < limit, TimelineProbe.timeline === images || TimelineProbe.layout?.counts.isEmpty != false {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard TimelineProbe.timeline !== images, let timeline = TimelineProbe.timeline, let layout = TimelineProbe.layout,
              let tracker = TimelineProbe.tracker, let scrollTo = TimelineProbe.scrollTo else {
            report += "\nThe big folder never opened as a timeline.\n"
            return
        }
        report += "\nA big folder\n\(timeline.count) entries in \(timeline.sections.count) sections after \(clock.now - opened), "
        report += "\(timeline.folders.count) folders, first section \(timeline.sections.first?.key.title(calendar: timeline.calendar) ?? "none")\n"
        let middle = layout.starts.count / 2
        scrollTo(layout.starts[middle])
        try? await Task.sleep(for: .milliseconds(400))
        report += "jump to \(timeline.sections[middle].key.title(calendar: timeline.calendar)): "
        report += "pinned \(tracker.pinned.map { timeline.sections[$0.section].key.title(calendar: timeline.calendar) } ?? "none")\n"

        // A new file in the folder: it's listed again, and the place in it stays.
        let place = tracker.offset
        if await addPicture(to: "Downloads", model: model, timeline: timeline) {
            try? await Task.sleep(for: .milliseconds(500))
            report += "a new file in the folder: \(abs(tracker.offset - place) < 200 ? "the place stays" : "WRONG, moved from \(Int(place)) to \(Int(tracker.offset))")\n"
        } else {
            report += "a new file in the folder: it never showed up\n"
        }
    }

    /// Real mouse and key events through the window: a click on a picture, arrow keys, across a month's edge too,
    /// a month's Select button and ⌘A.
    private static func clickAndType(_ model: AppModel, report: inout String, land: (Double) async -> String) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }), let content = window.contentView,
              let layout = TimelineProbe.layout, let metrics = TimelineProbe.metrics, let timeline = TimelineProbe.timeline,
              let tracker = TimelineProbe.tracker, let frame = TimelineProbe.frame?(), let selection = TimelineProbe.selection,
              layout.counts.count > 2 else { return }
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)

        func click(_ x: CGFloat, _ y: CGFloat) async {
            let point = NSPoint(x: x, y: content.frame.height - y)
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            // The release goes in the queue first: the press can start a loop that waits for it.
            if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
            if let down = event(.leftMouseDown) { window.sendEvent(down) }
            try? await Task.sleep(for: .milliseconds(120))
        }
        func press(_ character: Int, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) async {
            let text = String(UnicodeScalar(character).map(Character.init) ?? " ")
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: text,
                                                charactersIgnoringModifiers: text, isARepeat: false, keyCode: keyCode) {
                    window.sendEvent(event)
                }
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        func expect(_ name: String, _ position: Timeline.Position) -> String {
            let wanted = timeline.file(at: position)?.id
            let got = selection()
            return "\(name): \(got.count == 1 && got.first == wanted ? "right" : "WRONG, \(got.count) selected")\n"
        }

        report += "\nClicks and keys\n"
        let columns = layout.columns
        let month = 1
        _ = await land(layout.starts[month])
        let top = layout.y(ofItem: columns + 1, in: month) - tracker.offset
        await click(frame.minX + TimelineMetrics.padding + (metrics.itemWidth + metrics.spacing) * 1 + metrics.itemWidth / 2,
                    frame.minY + top + metrics.itemHeight / 2)
        report += expect("click on a picture", .init(section: month, item: columns + 1))
        await press(NSRightArrowFunctionKey, keyCode: 124, [.function, .numericPad])
        report += expect("right arrow", .init(section: month, item: columns + 2))
        await press(NSDownArrowFunctionKey, keyCode: 125, [.function, .numericPad])
        report += expect("down arrow", .init(section: month, item: columns * 2 + 2))
        await press(NSLeftArrowFunctionKey, keyCode: 123, [.function, .numericPad])
        report += expect("left arrow", .init(section: month, item: columns * 2 + 1))
        await press(NSUpArrowFunctionKey, keyCode: 126, [.function, .numericPad])
        await press(NSUpArrowFunctionKey, keyCode: 126, [.function, .numericPad])
        await press(NSUpArrowFunctionKey, keyCode: 126, [.function, .numericPad])
        let lastRow = (layout.counts[month - 1] - 1) / columns * columns
        report += expect("up over the month's edge", .init(section: month - 1, item: min(lastRow + 1, layout.counts[month - 1] - 1)))

        // With the pointer on a picture, the live spot lies over it: a click still lands on the picture, and its tick
        // adds a second one.
        _ = await land(layout.starts[month])
        let (x, y) = (frame.minX + TimelineMetrics.padding + metrics.itemWidth / 2, frame.minY + TimelineMetrics.headerHeight + metrics.itemHeight / 2)
        TimelineProbe.hover?.move(to: .init(section: month, item: 0))
        try? await Task.sleep(for: .milliseconds(100))
        await click(x, y)
        report += expect("click under the pointer", .init(section: month, item: 0))
        TimelineProbe.hover?.move(to: .init(section: month, item: 1))
        try? await Task.sleep(for: .milliseconds(100))
        await click(x + metrics.itemWidth + metrics.spacing - metrics.itemWidth / 2 + 16, y - metrics.itemHeight / 2 + 16)
        report += "the tick on a second picture: \(selection().count) selected of 2 wanted\n"
        TimelineProbe.hover?.move(to: nil)

        // A wider window: the rows change shape, and the same month stays at the top.
        let before = window.frame
        let month2 = tracker.pinned?.section
        let columnsBefore = TimelineProbe.layout?.columns ?? 0
        window.setFrame(NSRect(x: before.minX, y: before.minY, width: before.width + 340, height: before.height), display: true)
        try? await Task.sleep(for: .milliseconds(500))
        report += "wider window: \(columnsBefore) across became \(TimelineProbe.layout?.columns ?? 0), month \(tracker.pinned?.section == month2 ? "kept" : "LOST")\n"
        window.setFrame(before, display: true)
        try? await Task.sleep(for: .milliseconds(500))
        report += "back again: \(TimelineProbe.layout?.columns ?? 0) across, month \(tracker.pinned?.section == month2 ? "kept" : "LOST")\n"

        _ = await land(layout.starts[month])
        let selected = ContinuousClock.now
        await click(frame.maxX - TimelineMetrics.padding - TimelineMetrics.railWidth, frame.minY + TimelineMetrics.headerHeight / 2 + 6)
        let limit = ContinuousClock.now + .seconds(5)
        while selection().count < layout.counts[month], ContinuousClock.now < limit {
            try? await Task.sleep(for: .milliseconds(20))
        }
        report += "Select on a section: \(selection().count) selected of \(layout.counts[month]) after \(ContinuousClock.now - selected)\n"
        await press(0x61, keyCode: 0, .command)
        try? await Task.sleep(for: .milliseconds(500))
        report += "⌘A: \(selection().count) selected of \(timeline.count)\n"

        // A click on the pinned header isn't a click on the file hidden behind it.
        _ = await land(layout.starts[month] + 300)
        await click(frame.midX, frame.minY + 300)
        let picked = selection()
        await click(frame.midX, frame.minY + 26)
        report += "click on the pinned header: \(picked.count == 1 && selection() == picked ? "selection stays" : "WRONG, the selection changed")\n"

        // A new file moves everything after it: ⇧ can't extend from where the first click's file used to be.
        _ = await land(0)
        await click(frame.minX + TimelineMetrics.padding + (metrics.itemWidth + metrics.spacing) * 2 + metrics.itemWidth / 2,
                    frame.minY + layout.y(ofItem: 2, in: 0) + metrics.itemHeight / 2)
        if await addPicture(to: "Pictures/Trips/Lisbon", model: model, timeline: timeline) {
            await press(NSRightArrowFunctionKey, keyCode: 124, [.function, .numericPad, .shift])
            try? await Task.sleep(for: .milliseconds(200))
            report += "⇧-arrow after the files moved: \(selection().count == 1 ? "starts afresh" : "WRONG, \(selection().count) selected from a stale place")\n"
        } else {
            report += "⇧-arrow after the files moved: the new file never showed up\n"
        }

        // The way in from the overview: away and back keeps the place, and a click on a tile lands on what it shows.
        guard let setZoom = TimelineProbe.setZoom else { return }
        let byDate = TimelineProbe.opened?.grouping == .date
        let overview: TimelineZoom = byDate ? .months : .overview
        func title(_ section: Int?) -> String {
            section.flatMap { timeline.sections.indices.contains($0) ? timeline.sections[$0].key.title(calendar: timeline.calendar) : nil } ?? "none"
        }
        _ = await land(layout.starts[min(3, layout.starts.count - 1)])
        let place = tracker.pinned?.section
        setZoom(overview)
        try? await Task.sleep(for: .milliseconds(600))
        setZoom(.all)
        try? await Task.sleep(for: .milliseconds(800))
        let after = TimelineProbe.tracker?.pinned?.section
        report += "away to \(overview) and back: \(after == place ? "the same place" : "WRONG, \(title(place)) became \(title(after))")\n"

        setZoom(overview)
        try? await Task.sleep(for: .milliseconds(800))
        let (minimum, spacing, tileTop): (CGFloat, CGFloat, CGFloat) = byDate ? (160, 12, 120) : (250, 16, 100)
        let width = frame.width - TimelineMetrics.padding * 2
        let across = max(1, Int((width + spacing) / (minimum + spacing)))
        let tile = (width - spacing * CGFloat(across - 1)) / CGFloat(across)
        await click(frame.minX + TimelineMetrics.padding + tile + spacing + tile / 2, frame.minY + tileTop)
        try? await Task.sleep(for: .milliseconds(1_000))
        let wanted = byDate ? timeline.years[0].months[1].key : timeline.sections[1].key
        let landed = TimelineProbe.tracker?.pinned?.section
        let right = landed.map { timeline.sections[$0].key == wanted || timeline.sections[$0].key.containingMonth == wanted } ?? false
        report += "a click on the second tile: \(right ? "lands on it, \(title(landed))" : "WRONG, landed on \(title(landed))")\n"
    }

    /// Copies a picture on the demo disk, dated now, and waits for the timeline to show one more file.
    private static func addPicture(to folder: String, model: AppModel, timeline: Timeline) async -> Bool {
        guard model.options.scanRoot != nil else { return false }
        let path = Paths.join(model.realPath(model.homePath), folder)
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: path))?.first(where: { $0.hasSuffix(".jpg") }) else { return false }
        let copy = Paths.join(path, "added-\(UUID().uuidString).jpg")
        guard (try? FileManager.default.copyItem(atPath: Paths.join(path, name), toPath: copy)) != nil else { return false }
        try? FileManager.default.setAttributes([.creationDate: Date(), .modificationDate: Date()], ofItemAtPath: copy)
        let before = timeline.count
        let limit = ContinuousClock.now + .seconds(12)
        while timeline.count == before, ContinuousClock.now < limit {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(300))
        return timeline.count > before
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// The other ways of looking at a timeline, and what it took on this library.
    private static func renderTimelines(_ model: AppModel, images: Timeline?, directory: String) async {
        func save(_ page: some View, _ name: String) {
            for scheme in [ColorScheme.light, .dark] {
                render(page, model: model, scheme: scheme,
                       to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(scheme == .light ? "light" : "dark").png"))
            }
        }
        guard let images, !images.sections.isEmpty else { return }
        let clock = ContinuousClock()
        let started = clock.now
        let timed = Timeline()
        await timed.load(.library(model.library, query: BrowseFilters().query(for: .kind(.image)), grouping: .date, sort: .made),
                         keepingPages: false)
        let opened = clock.now - started

        save(TimelineSnapshot(scope: .kind(.image), timeline: images, grouping: .date, zoom: .all), "images-all")
        await images.loadPreviews(count: 3)
        for year in images.years {
            for file in images.cachedPreviews(of: year) {
                _ = await ThumbnailCache.shared.image(for: file.path, side: PictureTile.thumbnailSide)
            }
            for month in year.months {
                for file in images.cachedPreviews(of: month) {
                    _ = await ThumbnailCache.shared.image(for: file.path, side: MonthTile.thumbnailSide)
                }
            }
        }
        if images.years.isEmpty == false {
            save(TimelineSnapshot(scope: .kind(.image), timeline: images, grouping: .date, zoom: .months), "images-months")
        }
        save(TimelineSnapshot(scope: .kind(.image), timeline: images, grouping: .date, zoom: .years), "images-years")

        // Halfway down, just before a section's end, so the next header is pushing the pinned one up.
        let metrics = TimelineSnapshot.metrics(scope: .kind(.image), grouping: .date)
        let layout = metrics.layout(images.counts)
        let middle = images.sections.count / 2
        let offset = max(0, layout.starts[middle] - TimelineMetrics.headerHeight / 2)
        await loadWindow(images, metrics: metrics, window: offset..<(offset + Double(TimelineSnapshot.viewport)))
        save(TimelineSnapshot(scope: .kind(.image), timeline: images, grouping: .date, zoom: .all, offset: offset), "images-deep")

        let folders = await timeline(of: .kind(.document), model: model, grouping: .folder)
        save(TimelineSnapshot(scope: .kind(.document), timeline: folders, grouping: .folder, zoom: .all), "documents-folders")
        let sources = await timeline(of: .kind(.image), model: model, grouping: .source)
        save(TimelineSnapshot(scope: .kind(.image), timeline: sources, grouping: .source, zoom: .all), "images-sources")
        let byFolder = await timeline(of: .kind(.image), model: model, grouping: .folder)
        for section in byFolder.sections.prefix(16) {
            for file in await byFolder.previews(of: section, count: 3) {
                _ = await ThumbnailCache.shared.image(for: file.path, side: PictureTile.thumbnailSide)
            }
        }
        save(TimelineSnapshot(scope: .kind(.image), timeline: byFolder, grouping: .folder, zoom: .overview), "images-folders")
        var picked = Set<Int64>()
        for section in byFolder.sections.indices {
            byFolder.needIDs(in: section)
            if section < 2 { picked.formUnion(await byFolder.files(in: section).map(\.id)) }
        }
        try? await Task.sleep(for: .seconds(1))
        save(TimelineSnapshot(scope: .kind(.image), timeline: byFolder, grouping: .folder, zoom: .overview, selection: picked),
             "images-folders-picked")

        // A big folder of pictures: its folders on top, then its months.
        let listing = PlaceListing.list(Paths.join(model.realPath(model.homePath), "Downloads"), sizes: model.folderSize)
        if listing.style(layout: .grid) == .photos {
            let folder = Timeline()
            await folder.load(.files(listing.sections(calendar: folder.calendar), folders: listing.folders), keepingPages: false)
            await loadWindow(folder, metrics: metrics, window: 0..<Double(TimelineSnapshot.viewport))
            save(TimelineSnapshot(scope: .kind(.image), timeline: folder, grouping: .date, zoom: .all), "folder-timeline")
        }

        var report = "images: \(images.count), months: \(images.sections.count), years: \(images.years.count)\n"
        report += "timeline height: \(Int(layout.height)) points, \(layout.columns) across\n"
        report += "opening took \(opened)\n"
        try? report.write(toFile: Paths.join(directory, "timeline-check.txt"), atomically: true, encoding: .utf8)
    }

    /// Renders happen at once, so the thumbnails they show are made first.
    private static func loadThumbnails(_ model: AppModel, _ browsed: [IndexedFile]) async {
        for file in browsed {
            _ = await ThumbnailCache.shared.image(for: file.path, side: FileGrid.thumbnailSide)
        }
        for file in model.collections.duplicates.flatMap(\.files) {
            _ = await ThumbnailCache.shared.image(for: file.path, side: DuplicateGroupCard.side)
        }
        for file in model.collections.lookAlikes.flatMap(\.files) {
            _ = await ThumbnailCache.shared.image(for: file.path, side: LookAlikeGroupCard.side)
        }
        for file in model.collections.files.values.flatMap({ $0 }) {
            _ = await ThumbnailCache.shared.image(for: file.path, side: FileGrid.thumbnailSide)
        }
        let previews = model.collections.summaries.values.flatMap(\.preview)
        for file in previews {
            _ = await ThumbnailCache.shared.image(for: file.path, side: PileView.thumbnailSide)
            _ = await ThumbnailCache.shared.image(for: file.path, side: PileView.largeThumbnailSide)
        }
        for file in model.library.newest.values.flatMap({ $0 }) {
            _ = await ThumbnailCache.shared.image(for: file.path, side: HomeContent.mosaicSide)
            _ = await ThumbnailCache.shared.image(for: file.path, side: MosaicTile.thumbnailSide)
            _ = await ThumbnailCache.shared.image(for: file.path, side: PileView.thumbnailSide)
        }
        for file in model.library.sourcePreviews.values.flatMap({ $0 }) {
            _ = await ThumbnailCache.shared.image(for: file.path, side: SourceCard.thumbnailSide)
        }
        for file in model.library.recent.prefix(6) {
            _ = await ThumbnailCache.shared.image(for: file.path, side: HomeContent.recentSide)
        }
    }

    private static func mapState(focusedOn path: String, in tree: ScanTree) -> DiskMapState {
        var state = DiskMapState()
        if let id = tree.nodeID(forPath: path) { state.focus(on: id, in: tree) }
        return state
    }

    static func render(_ view: some View, model: AppModel, scheme: ColorScheme, height: CGFloat? = nil, to url: URL) {
        // Dynamic AppKit colors follow the drawing appearance, not SwiftUI's color scheme.
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            renderNow(view, model: model, scheme: scheme, height: height ?? size.height, to: url)
        }
    }

    private static func renderNow(_ view: some View, model: AppModel, scheme: ColorScheme, height: CGFloat, to url: URL) {
        // The canvas sits inside the color scheme too, or it would always be drawn light.
        let framed = view
            .tint(.unearth)
            .environment(model)
            .frame(width: size.width, height: height, alignment: .topLeading)
            .background(Color.canvas)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
/// The timeline on screen, so a debug run can drive the real scroll view.
@MainActor
enum TimelineProbe {
    private(set) static var timeline: Timeline?
    private(set) static var tracker: TimelineScroll?
    private(set) static var layout: SectionLayout?
    private(set) static var scrollTo: ((Double) -> Void)?
    /// The wheel handler for the pinned header and the rail: a point in the window, the content's height, how far.
    static var overlayWheel: ((NSPoint, CGFloat, Double) -> Bool)?
    static var hover: TimelineHover?
    /// What the screen opened at by itself, before being sent to every file for the check.
    static var opened: (grouping: FileGrouping, zoom: TimelineZoom)?
    /// Sends a browse screen to every file, whatever it would open at.
    static var opensEveryFile = false
    static var setZoom: ((TimelineZoom) -> Void)?
    static var zoom: (() -> TimelineZoom)?
    /// The folder tiles on screen, by position, in the window.
    static var tiles: [Int: CGRect] = [:]
    static var overviewTimeline: Timeline?
    static var overviewSelection: (() -> Set<Int64>)?
    static var clearOverviewSelection: (() -> Void)?
    /// How many groups Duplicates' page has.
    static var duplicateGroupsOnPage = 0
    /// A finished scan waits here before it goes on screen, so a check can move something behind its back.
    static var holdsScans = false
    static var heldScan: CheckedContinuation<Void, Never>?
    private(set) static var metrics: TimelineMetrics?
    private(set) static var frame: (() -> CGRect)?
    private(set) static var selection: (() -> Set<Int64>)?

    static func register(timeline: Timeline, tracker: TimelineScroll, layout: SectionLayout, metrics: TimelineMetrics,
                         frame: @escaping () -> CGRect, selection: @escaping () -> Set<Int64>,
                         scrollTo: @escaping (Double) -> Void) {
        self.timeline = timeline
        self.tracker = tracker
        self.layout = layout
        self.metrics = metrics
        self.frame = frame
        self.selection = selection
        self.scrollTo = scrollTo
    }
}

/// A browse screen as a timeline, drawn without a scroll view: its bar, then a screenful from `offset` down with
/// the header pinned as it would be, and the date rail; or the Years or Months view.
struct TimelineSnapshot: View {
    static let viewport: CGFloat = 790
    let scope: BrowseScope
    let timeline: Timeline
    let grouping: FileGrouping
    let zoom: TimelineZoom
    var offset: Double = 0
    var selection: Set<Int64> = []

    static func metrics(scope: BrowseScope, grouping: FileGrouping) -> TimelineMetrics {
        let rail = grouping == .date ? TimelineMetrics.railWidth - 12 : 0
        return TimelineMetrics(style: BrowseFilters().style(for: scope, layout: .grid), side: CardSize.medium.side,
                               width: DebugSnapshots.size.width - TimelineMetrics.padding * 2 - rail)
    }

    var body: some View {
        let kind = BrowseFilters().kind(for: scope)
        VStack(alignment: .leading, spacing: 0) {
            BrowseBar(scope: scope, filters: .constant(BrowseFilters()), zoom: .constant(zoom), grouping: grouping, timeline: timeline)
            switch zoom {
            case .years: TimelineYearsContent(timeline: timeline, kind: kind)
            case .months: TimelineMonthsContent(timeline: timeline, kind: kind)
            case .overview: TimelineOverviewContent(timeline: timeline, kind: kind, selection: .constant(selection))
            case .all: lines(kind: kind)
            }
        }
    }

    private func lines(kind: FileKind?) -> some View {
        let metrics = Self.metrics(scope: scope, grouping: grouping)
        let layout = metrics.layout(timeline.counts)
        let rail = grouping == .date ? TimelineMetrics.railWidth - 12 : 0
        let tracker = TimelineScroll()
        tracker.update(.init(offset: offset, viewport: Double(Self.viewport)), layout: layout)
        return ZStack(alignment: .topLeading) {
            TimelineLines(timeline: timeline, metrics: metrics, layout: layout,
                          window: offset..<(offset + Double(Self.viewport)), kind: kind,
                          selection: selection, trashing: .constant([]))
                .padding(.leading, TimelineMetrics.padding)
                .padding(.trailing, TimelineMetrics.padding + rail)
                .offset(y: -offset)
            PinnedTimelineHeader(timeline: timeline, tracker: tracker, kind: kind, selection: selection, onSelectSection: { _ in })
                .padding(.leading, TimelineMetrics.padding)
                .padding(.trailing, TimelineMetrics.padding + rail)
            if grouping == .date, layout.height > Double(Self.viewport) {
                DateRail(timeline: timeline, layout: layout, tracker: tracker, onScroll: { _ in })
                    .frame(maxWidth: .infinity, maxHeight: Self.viewport, alignment: .trailing)
            }
        }
        .frame(height: Self.viewport, alignment: .top)
        .clipped()
    }
}

/// The sidebar's sections drawn without a List, which ImageRenderer can't draw. Same rows, same order.
struct SidebarSnapshot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Sidebar.sections(model)) { section in
                if let title = section.title {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.secondaryInk)
                        .padding(.top, 12)
                        .padding(.leading, 8)
                }
                ForEach(section.rows) { row in
                    HStack {
                        SidebarRowLabel(row: row)
                        Spacer()
                        if let badge = row.badge {
                            Text(badge)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(row.highlighted ? Color.unearth : Color.secondaryInk)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(row.item == .home ? Color.unearth.opacity(0.9) : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .foregroundStyle(row.item == .home ? .white : Color.ink)
                }
            }
            Spacer(minLength: 16)
            LibraryStatusLine()
            FreeSpaceMeter()
        }
        .font(.system(size: 13))
        .padding(10)
        .frame(width: 240, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.sidebarFill)
        .background(Color.surface)
    }
}

/// Every Gallery component on one page, with the demo Library's files.
struct DesignSamples: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        let kinds = SidebarItem.libraryKinds.filter { library.count(of: $0) > 0 }
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Your Library", action: ("Browse all", {}))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(kinds, id: \.self) { kind in
                    MosaicTile(kind: kind, files: library.newest[kind] ?? [], count: library.count(of: kind),
                               bytes: library.bytes(of: kind))
                }
            }
            SectionHeader(title: "Worth a look", action: ("See all", {}))
            HStack(alignment: .top, spacing: 12) {
                PileView(items: [.symbol("shippingbox", .unearth), .symbol("hammer", .secondaryInk),
                                 .symbol("doc.zipper", .secondaryInk)],
                         title: "Caches & leftovers", bytes: 325_000_000_000, detail: "Safe to remove", highlighted: true)
                PileView(files: library.newest[.image] ?? [], title: "Duplicates", bytes: 3_100_000_000, detail: "214 extra copies")
                PileView(files: library.newest[.screenshot] ?? [], title: "Old screenshots", bytes: 30_000_000,
                         detail: "22 older than a month")
                PileView(items: [], title: "Unused apps", bytes: 0, detail: "Nothing here")
            }
            SectionHeader(title: "Downloaded from")
            HStack(spacing: 14) {
                ForEach(["ChatGPT", "Figma", "Slack", "Canva", "X", "example.org"], id: \.self) { name in
                    HStack(spacing: 8) {
                        Monogram(name: name)
                        Text(name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.ink)
                    }
                    .padding(9)
                    .galleryCard(radius: 12)
                }
            }
            HStack(alignment: .center, spacing: 18) {
                CountUpSize(bytes: 325_000_000_000)
                ForEach(SidebarItem.libraryKinds, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.symbol).foregroundStyle(kind.color).font(.callout)
                }
            }
            HStack(spacing: 0) {
                ForEach(CategoryStyle.order, id: \.self) { category in
                    Rectangle().fill(category.color).frame(height: 22)
                }
                Rectangle().fill(Color.freeSpace).frame(height: 22)
            }
            .clipShape(Capsule())
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.canvas)
    }
}

extension SidebarItem {
    /// The screens a snapshot run captures.
    static let snapshotItems: [SidebarItem] = [
        .home, .recents, .kind(.image), .downloadedFrom, .cleanUp, .storage, .systemData, .junk, .developer, .largeFiles,
        .diskMap,
    ] + CollectionKind.allCases.map(SidebarItem.collection)

    var snapshotName: String {
        switch self {
        case .kind(let kind): "kind-\(kind.rawValue)"
        case .source(let source): "source-\(source)"
        case .place(let path): "place-\((path as NSString).lastPathComponent)"
        case .collection(let kind): "collection-\(kind.rawValue)"
        default: String(describing: self)
        }
    }
}
#endif
