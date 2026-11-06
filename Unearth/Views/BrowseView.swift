import SwiftUI
import UnearthCore

/// What a browse screen lists.
enum BrowseScope: Hashable {
    case recents
    case kind(FileKind)
    case source(String)

    /// A screen for one kind doesn't need a kind filter.
    var showsKindFilter: Bool {
        if case .kind = self { false } else { true }
    }

    /// The ways the screen can split its files. Recents is one run, newest arrivals first.
    var groupings: [FileGrouping] {
        switch self {
        case .recents: []
        case .kind: [.date, .folder, .source, .none]
        case .source: [.date, .folder, .none]
        }
    }

    /// Where the screen's grouping is kept: one for each kind, one for all the sources.
    var groupingKey: String {
        switch self {
        case .recents: "browseGrouping.recents"
        case .kind(let kind): "browseGrouping.\(kind.rawValue)"
        case .source: "browseGrouping.source"
        }
    }
}

extension FileGrouping {
    var title: String {
        switch self {
        case .date: "Date"
        case .folder: "Folder"
        case .source: "Download source"
        case .none: "None"
        }
    }
}

/// The filters a browse screen offers, as chips.
struct BrowseFilters: Equatable {
    enum Added: String, CaseIterable {
        case today = "Added today", week = "Added this week", month = "Added this month"

        var component: Calendar.Component {
            switch self {
            case .today: .day
            case .week: .weekOfYear
            case .month: .month
            }
        }
    }

    static let sizes: [Int64] = [10_000_000, 100_000_000, 1_000_000_000]

    var minBytes: Int64?
    var added: Added?
    var kinds: Set<FileKind> = []

    var isEmpty: Bool { minBytes == nil && added == nil && kinds.isEmpty }

    func query(for scope: BrowseScope, now: Date = Date()) -> SearchQuery {
        var query = SearchQuery()
        switch scope {
        case .recents: break
        case .kind(let kind): query.kinds = [kind]
        case .source(let source): query.source = source
        }
        if scope.showsKindFilter { query.kinds.formUnion(kinds) }
        query.minBytes = minBytes
        query.added = added.flatMap { Calendar.current.dateInterval(of: $0.component, for: now) }
        return query
    }

    /// The one kind the screen shows, if it's one: "412 images" rather than "412 files".
    func kind(for scope: BrowseScope) -> FileKind? {
        if case .kind(let kind) = scope { return kind }
        return kinds.count == 1 ? kinds.first : nil
    }

    /// Pictures edge to edge when every file is a picture or a video; cards with names otherwise.
    func style(for scope: BrowseScope, layout: FileLayout) -> TimelineStyle {
        guard layout == .grid else { return .list }
        let kinds: Set<FileKind> = if case .kind(let kind) = scope { [kind] } else { kinds }
        return !kinds.isEmpty && kinds.isSubset(of: [.image, .screenshot, .video]) ? .photos : .cards
    }
}

struct BrowseView: View {
    @Environment(AppModel.self) private var model
    let scope: BrowseScope
    @State private var files: [IndexedFile] = []
    @State private var exhausted = true
    @State private var loading = false
    /// Bumped by every load, so a page that arrives after a newer load is dropped.
    @State private var loads = 0
    @State private var filters = BrowseFilters()
    @State private var selection: Set<Int64> = []
    @State private var trashing: [IndexedFile] = []
    @State private var timeline = Timeline()
    @State private var zoom = TimelineZoom.all
    @State private var trail = BackTrail<TimelineZoom>()
    @AppStorage private var sort: FileSort
    @AppStorage("browseLayout") private var layout: FileLayout = .grid
    /// What Group by was set to. Until it is, the files' own spread decides.
    @AppStorage private var chosenGrouping: FileGrouping?
    /// The grouping that suits the files, worked out as they load.
    @State private var fittingGrouping = FileGrouping.date

    init(scope: BrowseScope) {
        self.scope = scope
        // Recents is about what arrived lately, whenever it was made.
        _sort = scope == .recents ? AppStorage(wrappedValue: .added, "browseSort.recents") : AppStorage(wrappedValue: .made, "browseSort")
        _chosenGrouping = AppStorage(scope.groupingKey)
    }

    private struct LoadKey: Equatable {
        let filters: BrowseFilters
        let sort: FileSort
        let chosenGrouping: FileGrouping?
    }

    /// The grouping in force: one the screen offers.
    private var shownGrouping: FileGrouping {
        let wanted = chosenGrouping ?? fittingGrouping
        return scope.groupings.contains(wanted) ? wanted : scope.groupings.first ?? .none
    }

    var body: some View {
        let grouping = shownGrouping
        VStack(alignment: .leading, spacing: 0) {
            BrowseBar(scope: scope, filters: $filters, zoom: $zoom, trail: $trail, grouping: grouping,
                      timeline: grouping == .none ? nil : timeline)
            if grouping == .none {
                ScrollViewReader { proxy in
                    ScrollView {
                        BrowseContent(scope: scope, files: files, filters: filters, selection: $selection, trashing: $trashing,
                                      layout: layout, onReachEnd: loadMore, onCursor: { proxy.scrollTo($0) })
                    }
                }
            } else if timeline.isLoaded, timeline.sections.isEmpty {
                BrowseEmpty(filters: filters)
                Spacer(minLength: 0)
            } else {
                TimelineScreen(timeline: timeline, zoom: $zoom, style: filters.style(for: scope, layout: layout),
                               kind: filters.kind(for: scope), grouping: grouping, selection: $selection, trashing: $trashing,
                               trail: $trail)
            }
        }
        .background(Color.canvas)
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                SelectionBar(files: selectedFiles, trashing: $trashing, selection: $selection, note: pickedTiles)
            }
        }
        .toolbar {
            BrowseToolbar(sort: $sort, layout: $layout,
                          grouping: scope.groupings.isEmpty ? nil : Binding(get: { grouping }, set: { chosenGrouping = $0 }),
                          groupings: scope.groupings)
        }
        .trashConfirmation($trashing)
        // New filters, sort or grouping start from the top; a change in the Library reloads what's shown, in place.
        .task(id: LoadKey(filters: filters, sort: sort, chosenGrouping: chosenGrouping)) { await load(keepingWhatsShown: false) }
        .onChange(of: model.library.revision) { Task { await load(keepingWhatsShown: true) } }
        #if DEBUG
        .onAppear {
            TimelineProbe.setZoom = { zoom = $0 }
            TimelineProbe.zoom = { zoom }
        }
        #endif
    }

    /// On the overview, how many folders or sources the selection is: "in 3 folders".
    private var pickedTiles: String? {
        let grouping = shownGrouping
        guard zoom.fitted(to: grouping) == .overview else { return nil }
        let tiles = timeline.wholeSections(in: selection)
        guard tiles > 0 else { return nil }
        let (one, many) = grouping == .source ? ("source", "sources") : ("folder", "folders")
        return "in \(tiles.formatted()) \(tiles == 1 ? one : many)"
    }

    private var selectedFiles: [IndexedFile] {
        shownGrouping == .none ? files.filter { selection.contains($0.id) } : selection.compactMap { timeline.known[$0] }
    }

    private func load(keepingWhatsShown: Bool) async {
        let query = filters.query(for: scope)
        // While the screen is open its grouping stays put, however the Library changes under it.
        if !keepingWhatsShown, chosenGrouping == nil, !scope.groupings.isEmpty {
            fittingGrouping = await model.library.fittingGrouping(matching: query, calendar: timeline.calendar)
        }
        let grouping = shownGrouping
        guard grouping == .none else {
            await timeline.load(.library(model.library, query: query, grouping: grouping, sort: sort),
                                keepingPages: keepingWhatsShown)
            if !keepingWhatsShown {
                zoom = TimelineZoom.opening(grouping, count: timeline.count)
                trail = BackTrail()
            }
            #if DEBUG
            if !keepingWhatsShown, TimelineProbe.opensEveryFile {
                TimelineProbe.opened = (grouping, zoom)
                zoom = .all
            }
            #endif
            // The selection keeps only files still in the Library and still on the screen.
            guard !selection.isEmpty else { return }
            let checked = selection
            let still = await model.library.files(ids: Array(checked))
            let shown = Set(await model.library.ids(matching: query))
            let kept = still.filter { shown.contains($0.id) }
            timeline.remember(kept)
            selection.subtract(checked.subtracting(kept.map(\.id)))
            return
        }
        loads += 1
        let load = loads
        let count = keepingWhatsShown ? max(files.count, LibraryModel.pageSize) : LibraryModel.pageSize
        let rows = await model.library.files(matching: query, sort: sort, limit: count, offset: 0)
        guard load == loads else { return }
        files = rows
        exhausted = rows.count < count
        selection.formIntersection(rows.map(\.id))
    }

    private func loadMore() {
        guard !exhausted, !loading else { return }
        loading = true
        let load = loads
        let offset = files.count
        Task {
            let next = await model.library.files(matching: filters.query(for: scope), sort: sort, limit: LibraryModel.pageSize,
                                                 offset: offset)
            loading = false
            guard load == loads else { return }
            let shown = Set(files.map(\.id))
            files += next.filter { !shown.contains($0.id) }
            exhausted = next.count < LibraryModel.pageSize
        }
    }
}

/// Grouping, sort order and grid or list, in the window's toolbar.
struct BrowseToolbar: ToolbarContent {
    @Binding var sort: FileSort
    @Binding var layout: FileLayout
    /// Nil where the screen can't be grouped.
    var grouping: Binding<FileGrouping>?
    var groupings: [FileGrouping] = []
    /// A folder's timeline is newest first, whatever the sort.
    var showsSort = true

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            if let grouping {
                Picker("Group by", selection: grouping) {
                    ForEach(groupings, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Group files by date, folder or where they were downloaded from")
            }
            if showsSort {
                Picker("Sort by", selection: $sort) {
                    Text("Date created").tag(FileSort.made)
                    Text("Date added").tag(FileSort.added)
                    Text("Name").tag(FileSort.name)
                    Text("Size").tag(FileSort.size)
                    Text("Kind").tag(FileSort.kind)
                }
                .pickerStyle(.menu)
                .help("Sort files")
            }
            Picker("View", selection: $layout) {
                Label("Grid", systemImage: "square.grid.2x2").tag(FileLayout.grid)
                Label("List", systemImage: "list.bullet").tag(FileLayout.list)
            }
            .pickerStyle(.segmented)
            .help("Show files as a grid or a list")
        }
    }
}

/// The top of a browse screen, fixed above the files: how many there are and the filters, and on a timeline the
/// switch between Years, Months and All.
struct BrowseBar: View {
    @Environment(AppModel.self) private var model
    let scope: BrowseScope
    @Binding var filters: BrowseFilters
    var zoom: Binding<TimelineZoom>?
    var trail: Binding<BackTrail<TimelineZoom>>?
    var grouping = FileGrouping.none
    var timeline: Timeline?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let summary { Text(summary).font(.title3).monospacedDigit().foregroundStyle(Color.secondaryInk) }
            HStack(spacing: 16) {
                if let zoom, let trail, let step = trail.wrappedValue.last {
                    BackButton(destination: step.title(for: grouping)) {
                        if let step = trail.wrappedValue.back() { zoom.wrappedValue = step }
                    }
                }
                FilterChips(filters: $filters, showsKinds: scope.showsKindFilter)
                Spacer(minLength: 0)
                if let zoom, let timeline, !timeline.sections.isEmpty {
                    TimelineZoomPills(zoom: zoom, timeline: timeline, grouping: grouping)
                }
            }
        }
        .padding(.horizontal, TimelineMetrics.padding)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "6 files, 1 MB" for the whole screen, before filters.
    private var summary: String? {
        let library = model.library
        let (count, bytes): (Int, Int64) = switch scope {
        case .recents: (library.kinds.reduce(0) { $0 + $1.count }, library.kinds.reduce(0) { $0 + $1.bytes })
        case .kind(let kind): (library.count(of: kind), library.bytes(of: kind))
        case .source(let source): library.sources.first { $0.source == source }.map { ($0.count, $0.bytes) } ?? (0, 0)
        }
        guard count > 0 else { return nil }
        return "\(count == 1 ? "1 file" : "\(count.formatted()) files"), \(ByteFormatting.string(bytes))"
    }
}

/// A browse screen's files in one run, without its scroll view, so it can also be rendered to an image.
struct BrowseContent: View {
    let scope: BrowseScope
    let files: [IndexedFile]
    let filters: BrowseFilters
    @Binding var selection: Set<Int64>
    @Binding var trashing: [IndexedFile]
    var layout: FileLayout = .grid
    var onReachEnd: () -> Void = {}
    var onCursor: (Int64) -> Void = { _ in }

    var body: some View {
        Group {
            if files.isEmpty {
                BrowseEmpty(filters: filters)
            } else {
                FileGrid(files: files, layout: layout, selection: $selection, trashing: $trashing, onReachEnd: onReachEnd,
                         onCursor: onCursor)
            }
        }
        .padding(.horizontal, TimelineMetrics.padding)
        .padding(.top, 10)
        .padding(.bottom, TimelineMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What a browse screen says when it has nothing to show.
struct BrowseEmpty: View {
    @Environment(AppModel.self) private var model
    let filters: BrowseFilters

    var body: some View {
        ContentUnavailableView(filters.isEmpty ? "Nothing here yet" : "No files match these filters", systemImage: "tray",
                               description: Text(filters.isEmpty ? emptyHint : "Remove a filter to see more."))
            .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var emptyHint: String {
        switch model.library.status {
        case .indexing: "Unearth is still building your Library."
        default: "Files in your Library folders show up here."
        }
    }
}

/// Size, date and kind filters, as menus that look like chips.
struct FilterChips: View {
    @Binding var filters: BrowseFilters
    let showsKinds: Bool

    var body: some View {
        HStack(spacing: 8) {
            chip(filters.minBytes.map { "Over \(ByteFormatting.string($0))" } ?? "Any size", active: filters.minBytes != nil,
                 clear: { filters.minBytes = nil }) {
                ForEach(BrowseFilters.sizes, id: \.self) { bytes in
                    Button("Over \(ByteFormatting.string(bytes))") { filters.minBytes = bytes }
                }
            }
            chip(filters.added?.rawValue ?? "Any time", active: filters.added != nil, clear: { filters.added = nil }) {
                ForEach(BrowseFilters.Added.allCases, id: \.self) { added in
                    Button(added.rawValue) { filters.added = added }
                }
            }
            if showsKinds {
                let names = SidebarItem.libraryKinds.filter(filters.kinds.contains).map(\.title)
                chip(names.isEmpty ? "All kinds" : names.joined(separator: ", "), active: !names.isEmpty, clear: { filters.kinds = [] }) {
                    ForEach(SidebarItem.libraryKinds, id: \.self) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { filters.kinds.contains(kind) },
                            set: { if $0 { filters.kinds.insert(kind) } else { filters.kinds.remove(kind) } }))
                    }
                }
            }
        }
    }

    private func chip<Items: View>(_ title: String, active: Bool, clear: @escaping () -> Void,
                                   @ViewBuilder items: () -> Items) -> some View {
        HStack(spacing: 4) {
            Menu {
                items()
            } label: {
                Text(title).lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            if active {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remove \(title) filter")
            }
            if !active {
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.ink))
        .background(active ? AnyShapeStyle(Color.unearth.opacity(0.14)) : AnyShapeStyle(Color.surface), in: Capsule())
        .overlay { Capsule().strokeBorder(active ? Color.unearth.opacity(0.5) : Color.hairline) }
    }
}

// MARK: - Downloaded from

struct SourcesView: View {
    var body: some View {
        ScrollView { SourcesContent() }
            .background(Color.canvas)
    }
}

/// Every place downloads came from, read from the record macOS keeps with each download.
struct SourcesContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        let (big, small) = SourceCard.split(library.sources)
        VStack(alignment: .leading, spacing: 18) {
            Text("Where your downloads came from, from the record macOS keeps with each download.")
                .font(.title3)
                .foregroundStyle(Color.secondaryInk)
            if library.sources.isEmpty {
                ContentUnavailableView("No downloads with a source yet", systemImage: "tray.and.arrow.down",
                                       description: Text("Files you download with Safari, Chrome or most other apps show up here."))
                    .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                    ForEach(big, id: \.source) { source in
                        Button { model.sidebarSelection = .source(source.source) } label: {
                            SourceCard(name: source.source, count: source.count, bytes: source.bytes,
                                       previews: library.sourcePreviews[source.source] ?? [])
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !small.isEmpty {
                    SectionHeader(title: SourceCard.otherWebsites)
                    VStack(spacing: 0) {
                        ForEach(Array(small.enumerated()), id: \.element.source) { index, source in
                            if index > 0 { Divider().padding(.leading, 48) }
                            Button { model.sidebarSelection = .source(source.source) } label: {
                                HStack(spacing: 10) {
                                    Monogram(name: source.source, side: 24)
                                    Text(source.source).foregroundStyle(Color.ink)
                                    Spacer()
                                    Text(source.count == 1 ? "1 file" : "\(source.count.formatted()) files")
                                        .monospacedDigit()
                                        .foregroundStyle(Color.secondaryInk)
                                    SizeLabel(bytes: source.bytes).foregroundStyle(Color.secondaryInk)
                                        .frame(width: 70, alignment: .trailing)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .galleryCard()
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
