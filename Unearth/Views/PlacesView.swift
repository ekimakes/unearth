import SwiftUI
import UnearthCore

/// A folder as it is right now, folders first. Opening a folder goes into it. A folder of a few files is a grid
/// in the sort order; a big one is a timeline, unless Group by says otherwise.
struct PlacesView: View {
    @Environment(AppModel.self) private var model
    let root: String
    @State private var folder: String
    @State private var listing = PlaceListing.empty
    @State private var selection: Set<Int64> = []
    @State private var trashing: [IndexedFile] = []
    @State private var sort: FileSort = .name
    @State private var timeline = Timeline()
    @State private var zoom = TimelineZoom.all
    /// The tiles opened in this folder's timeline.
    @State private var trail = BackTrail<TimelineZoom>()
    /// The folder Back just came out of, to land on it.
    @State private var leftFolder: String?
    /// What Group by was set to; until then, the folder's size decides.
    @State private var chosenGrouping: FileGrouping?
    /// The folder the timeline holds: listing it again keeps the place, a new one starts at the top.
    @State private var listedFolder: String?
    @AppStorage("browseLayout") private var layout: FileLayout = .grid

    init(root: String) {
        self.root = root
        _folder = State(initialValue: root)
    }

    private struct LoadKey: Equatable {
        let folder: String
        let revision: Int
        let scan: UUID?
        let sort: FileSort
    }

    private var grouping: FileGrouping { chosenGrouping ?? listing.fittingGrouping }

    /// Where Back goes: out of a year or a month first, then up a folder. Nothing at the top of the place.
    private var backDestination: String? {
        if let step = trail.last { return step.title(for: .date) }
        return Paths.parent(of: folder, within: root).map { $0 == root ? SidebarItem.place(root).title : ($0 as NSString).lastPathComponent }
    }

    private func goBack() {
        if let step = trail.back() {
            zoom = step
        } else if let parent = Paths.parent(of: folder, within: root) {
            leftFolder = folder
            folder = parent
        }
    }

    var body: some View {
        let grouping = grouping
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                if let backDestination { BackButton(destination: backDestination, action: goBack) }
                PlacesBreadcrumb(root: root, folder: $folder)
                Spacer(minLength: 0)
                if grouping == .date, !timeline.sections.isEmpty {
                    TimelineZoomPills(zoom: $zoom, timeline: timeline, grouping: .date)
                }
            }
            .padding(.horizontal, TimelineMetrics.padding)
            .padding(.top, 22)
            .padding(.bottom, 8)
            if grouping == .none || listing.entries.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        PlacesContent(folder: $folder, listing: listing, selection: $selection, trashing: $trashing, layout: layout,
                                      onCursor: { proxy.scrollTo($0) })
                    }
                    .onChange(of: listing) {
                        if let left = listing.entries.first(where: { $0.path == leftFolder }) { proxy.scrollTo(left.id, anchor: .center) }
                    }
                }
            } else {
                TimelineScreen(timeline: timeline, zoom: $zoom, style: listing.style(layout: layout), kind: nil, grouping: .date,
                               selection: $selection, trashing: $trashing, trail: $trail, onOpenFolder: { folder = $0.path })
                    .id(folder)
            }
        }
        .background(Color.canvas)
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                SelectionBar(files: listing.entries.filter { selection.contains($0.id) }, trashing: $trashing, selection: $selection)
            }
        }
        .toolbar {
            BrowseToolbar(sort: $sort, layout: $layout,
                          grouping: Binding(get: { grouping }, set: { chosenGrouping = $0 }), groupings: [.date, .none],
                          showsSort: grouping == .none)
        }
        .trashConfirmation($trashing)
        .task(id: LoadKey(folder: folder, revision: model.library.revision, scan: model.tree?.id, sort: sort)) {
            // Listing a big folder takes seconds; it happens off the main thread.
            let (folder, sort, sizes, calendar) = (folder, sort, model.scannedSizes, timeline.calendar)
            let (listed, sections) = await Task.detached(priority: .userInitiated) {
                let listed = PlaceListing.list(folder, sort: sort, sizes: sizes)
                return (listed, listed.sections(calendar: calendar))
            }.value
            guard !Task.isCancelled else { return }
            listing = listed
            selection.formIntersection(listed.entries.map(\.id))
            let sameFolder = listedFolder == folder
            listedFolder = folder
            await timeline.load(.files(sections, folders: listed.folders), keepingPages: sameFolder)
        }
        .onChange(of: folder) {
            selection = []
            trail = BackTrail()
        }
        #if DEBUG
        .onAppear {
            TimelineProbe.placesFolder = { folder }
            TimelineProbe.setPlacesFolder = { folder = $0 }
        }
        #endif
    }
}

/// Where the folder is, from the place it was opened from.
struct PlacesBreadcrumb: View {
    let root: String
    @Binding var folder: String

    var body: some View {
        let below = folder.dropFirst(root.count).split(separator: "/").map(String.init)
        let chain = [root] + below.indices.map { Paths.join(root, below[...$0].joined(separator: "/")) }
        HStack(spacing: 6) {
            ForEach(Array(chain.enumerated()), id: \.element) { index, path in
                if index > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                Button(index == 0 ? SidebarItem.place(root).title : (path as NSString).lastPathComponent) { folder = path }
                    .buttonStyle(.plain)
                    .foregroundStyle(path == folder ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                    .fontWeight(path == folder ? .semibold : .regular)
            }
        }
        .font(.title3)
        .lineLimit(1)
    }
}

/// A folder's contents as a grid, without the scroll view.
struct PlacesContent: View {
    @Binding var folder: String
    let listing: PlaceListing
    @Binding var selection: Set<Int64>
    @Binding var trashing: [IndexedFile]
    var layout: FileLayout = .grid
    var onCursor: (Int64) -> Void = { _ in }

    var body: some View {
        Group {
            if listing.entries.isEmpty {
                ContentUnavailableView("This folder is empty", systemImage: "folder")
                    .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                FileGrid(files: listing.entries, layout: layout, selection: $selection, trashing: $trashing,
                         folders: listing.folders, onOpenFolder: { folder = $0.path }, showsFolder: false, onCursor: onCursor)
            }
        }
        .padding(.horizontal, TimelineMetrics.padding)
        .padding(.top, 10)
        .padding(.bottom, TimelineMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One folder's visible contents, as Library files. Folders get their size from the last disk scan.
struct PlaceListing: Equatable {
    var entries: [IndexedFile]
    var folders: Set<Int64>

    static let empty = PlaceListing(entries: [], folders: [])
    /// From this many files, a folder opens as a timeline.
    static let manyFiles = 200
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey,
        .creationDateKey, .ubiquitousItemDownloadingStatusKey,
    ]

    private var files: [IndexedFile] { entries.filter { !folders.contains($0.id) } }

    /// A timeline for a big folder; a folder of a few files reads best as a grid in the sort order.
    var fittingGrouping: FileGrouping { entries.count - folders.count >= Self.manyFiles ? .date : .none }

    /// Pictures edge to edge when nearly everything in the folder is a picture or a video.
    func style(layout: FileLayout) -> TimelineStyle {
        guard layout == .grid else { return .list }
        let files = files
        let pictures = files.filter { [.image, .screenshot, .video].contains($0.kind) }.count
        return !files.isEmpty && pictures * 5 >= files.count * 4 ? .photos : .cards
    }

    /// The listing as a timeline: its folders, then its files by month.
    func sections(calendar: Calendar) -> [(section: FileSection, files: [IndexedFile])] {
        var sections = FileSection.group(files, by: .date, calendar: calendar)
        let subfolders = entries.filter { folders.contains($0.id) }
        if !subfolders.isEmpty {
            let section = FileSection(key: .subfolders, count: subfolders.count, bytes: subfolders.reduce(0) { $0 + $1.bytes })
            sections.insert((section, subfolders), at: 0)
        }
        return sections
    }

    /// Folders first, then everything in `sort` order.
    static func list(_ folder: String, sort: FileSort = .name, sizes: (String) -> Int64?) -> PlaceListing {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var entries: [(file: IndexedFile, isFolder: Bool)] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            let name = url.lastPathComponent
            let modified = values?.contentModificationDate ?? .distantPast
            let bytes = values?.isDirectory == true ? sizes(url.path) ?? 0 : Int64(values?.fileSize ?? 0)
            let file = IndexedFile(
                id: Int64(truncatingIfNeeded: url.path.hashValue), path: url.path, name: name, parent: folder,
                kind: isFolder ? .other : FileClassifier.kind(forName: name, isScreenshot: false),
                fileExtension: isFolder ? "" : FileClassifier.fileExtension(name), bytes: bytes,
                created: values?.creationDate, modified: modified,
                added: values?.addedToDirectoryDate ?? values?.creationDate ?? modified, source: nil,
                isCloudOnly: values?.ubiquitousItemDownloadingStatus == .notDownloaded)
            entries.append((file, isFolder))
        }
        entries.sort { left, right in
            if left.isFolder != right.isFolder { return left.isFolder }
            let (a, b) = (left.file, right.file)
            switch sort {
            case .made where a.made != b.made: return a.made > b.made
            case .added where a.added != b.added: return a.added > b.added
            case .size where a.bytes != b.bytes: return a.bytes > b.bytes
            case .kind where a.kind != b.kind: return a.kind.title < b.kind.title
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        return PlaceListing(entries: entries.map(\.file), folders: Set(entries.filter(\.isFolder).map(\.file.id)))
    }
}
