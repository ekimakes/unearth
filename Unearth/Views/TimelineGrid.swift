import AppKit
import SwiftUI
import UnearthCore

/// How a timeline draws its files.
enum TimelineStyle: Equatable {
    /// Pictures edge to edge, as in a photo library; names show on hover and in Quick Look.
    case photos
    /// Cards with names, for documents and everything else.
    case cards
    /// One file a row.
    case list
}

/// The sizes of a timeline's parts, from the card size and the width there is.
struct TimelineMetrics: Equatable {
    static let headerHeight: CGFloat = 52
    static let padding: CGFloat = 28
    static let railWidth: CGFloat = 44

    let style: TimelineStyle
    let columns: Int
    let itemWidth: CGFloat
    let itemHeight: CGFloat
    let spacing: CGFloat
    let rowHeight: CGFloat
    /// The size thumbnails are made at, whatever size they're shown at, so the cache keeps them.
    let thumbnailSide: CGFloat

    init(style: TimelineStyle, side: CGFloat, width: CGFloat) {
        self.style = style
        thumbnailSide = side
        switch style {
        case .photos:
            spacing = 4
            columns = GridNavigation.columns(width: width, itemWidth: side, spacing: spacing)
            // Pictures stretch a little to fill the row, as in Photos.
            itemWidth = max(40, ((width - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down))
            itemHeight = itemWidth
            rowHeight = itemHeight + spacing
        case .cards:
            spacing = 14
            columns = GridNavigation.columns(width: width, itemWidth: side + 12, spacing: spacing)
            itemWidth = side + 12
            itemHeight = FileCard.height(side: side)
            rowHeight = itemHeight + 16
        case .list:
            spacing = 0
            columns = 1
            itemWidth = max(0, width)
            itemHeight = FileRow.height
            rowHeight = FileRow.height
        }
    }

    func layout(_ counts: [Int]) -> SectionLayout {
        SectionLayout(counts: counts, columns: columns, headerHeight: Self.headerHeight, rowHeight: rowHeight)
    }
}

/// Where a timeline is scrolled to. Its parts change at different rates and each view reads only the one it
/// needs: the rail follows every point, the pinned header changes near a section's edge, and the rows drawn change
/// a row at a time.
@MainActor @Observable
final class TimelineScroll {
    struct State: Equatable {
        let offset: Double
        let viewport: Double
    }

    private(set) var offset: Double = 0
    private(set) var viewport: Double = 0
    /// The furthest down the timeline can go.
    private(set) var scrollable: Double = 0
    /// The stretch drawn: what's in view and half a screen above and below.
    private(set) var window: Range<Double> = 0..<1_600
    private(set) var pinned: SectionLayout.Pinned?
    /// The window the timeline is in.
    @ObservationIgnored weak var hostWindow: NSWindow?
    /// Whether the wheel gesture under way began over the pinned header or the rail.
    @ObservationIgnored var wheelOverOverlay = false

    func update(_ state: State, layout: SectionLayout) {
        if state.offset != offset { offset = state.offset }
        if state.viewport != viewport { viewport = state.viewport }
        scrollable = max(0, layout.height - state.viewport)
        let screen = max(400, state.viewport)
        let step = max(100, layout.rowHeight)
        let top = max(0, ((state.offset - screen / 2) / step).rounded(.down) * step)
        let window = top..<(top + screen * 2 + step)
        if window != self.window { self.window = window }
        let pinned = layout.pinnedHeader(at: max(0, state.offset))
        if pinned != self.pinned { self.pinned = pinned }
    }

    func relayout(_ layout: SectionLayout) {
        update(State(offset: offset, viewport: viewport), layout: layout)
    }
}

/// A screen's files in sections, however many: only the rows in view are drawn, every section takes its exact
/// height from its count before its files arrive, the header of the section at the top stays pinned, and a rail
/// down the right edge jumps to any month. Selection works as in a `FileGrid`: click, ⌘-click, ⇧-click, the arrow
/// keys (⇧ extends), Return opens, Space shows Quick Look, ⌘A selects everything and ⌘⌫ asks to move the
/// selection to the Trash.
struct TimelineGrid: View {
    @Environment(AppModel.self) private var model
    let timeline: Timeline
    let style: TimelineStyle
    /// What the files are, for counts: "412 images". Nil when they're of many kinds.
    let kind: FileKind?
    /// Whether the date rail shows: on a timeline of months.
    let showsRail: Bool
    @Binding var selection: Set<Int64>
    @Binding var trashing: [IndexedFile]
    /// A section to bring to the top, set by the Months view; cleared once shown.
    @Binding var jump: FileSection.Key?
    /// Opens a folder in a folder's listing.
    var onOpenFolder: (IndexedFile) -> Void = { _ in }
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var tracker = TimelineScroll()
    /// Where the timeline is in the window.
    @State private var frame = CGRect.zero
    @State private var wheelMonitor: Any?
    @State private var cursor: Timeline.Position?
    @State private var anchor: GridNavigation.Anchor?
    /// Bumped by every change of selection, so what an older one finds late doesn't overwrite a newer one.
    @State private var choices = 0
    @FocusState private var focused: Bool
    @AppStorage("cardSize") private var cardSize: CardSize = .medium

    /// Whether room is kept for the date rail, which shows once there's something to scroll through.
    private var railShown: Bool { showsRail && timeline.sections.count > 1 }
    private var trailing: CGFloat { TimelineMetrics.padding + (railShown ? TimelineMetrics.railWidth - 12 : 0) }
    private var width: CGFloat { frame.width }

    var body: some View {
        let metrics = TimelineMetrics(style: style, side: cardSize.side, width: width - TimelineMetrics.padding - trailing)
        let layout = metrics.layout(timeline.counts)
        ScrollView {
            TimelineLines(timeline: timeline, metrics: metrics, layout: layout, window: tracker.window, kind: kind,
                          selection: selection, trashing: $trashing, onClick: { click($0, toggling: $1) },
                          onSelectSection: { selectSection($0) },
                          isCovered: { tracker.offset > 0.5 && $0 < tracker.offset + TimelineMetrics.headerHeight })
                .padding(.leading, TimelineMetrics.padding)
                .padding(.trailing, trailing)
                .padding(.bottom, TimelineMetrics.padding)
        }
        .scrollPosition($scroll)
        .scrollIndicators(railShown ? .never : .automatic)
        .onScrollGeometryChange(for: TimelineScroll.State.self) { geometry in
            TimelineScroll.State(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                                 viewport: geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom)
        } action: { _, state in
            tracker.update(state, layout: layout)
        }
        .onChange(of: layout, initial: true) { old, new in
            keepPlace(from: old, to: new)
            tracker.relayout(new)
            #if DEBUG
            TimelineProbe.register(timeline: timeline, tracker: tracker, layout: new, metrics: metrics, frame: { frame },
                                   selection: { selection }, scrollTo: { scroll.scrollTo(y: $0) })
            #endif
        }
        .overlay(alignment: .top) {
            PinnedTimelineHeader(timeline: timeline, tracker: tracker, kind: kind, selection: selection,
                                 onSelectSection: { selectSection($0) })
                .padding(.leading, TimelineMetrics.padding)
                .padding(.trailing, trailing)
        }
        .overlay(alignment: .trailing) {
            if railShown, layout.height > tracker.viewport {
                DateRail(timeline: timeline, layout: layout, tracker: tracker) { scroll.scrollTo(y: $0) }
            }
        }
        .onChange(of: timeline.restarts) {
            scroll.scrollTo(edge: .top)
            choices += 1
            cursor = nil
            anchor = nil
        }
        .onChange(of: selection) { choices += 1 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .background(WindowReader { tracker.hostWindow = $0 })
        .onAppear { handOnTheWheel() }
        .onDisappear {
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
            // Off to the Years or Months view: coming back lands on this month rather than at the top.
            if tracker.offset > 0.5, let section = tracker.pinned?.section, timeline.sections.indices.contains(section) {
                jump = timeline.sections[section].key
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
            move(press.key, extending: press.modifiers.contains(.shift), layout: layout) ? .handled : .ignored
        }
        .onKeyPress(.return) {
            let chosen = selectedFiles
            guard !chosen.isEmpty else { return .ignored }
            open(chosen)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "a"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selectLater { await timeline.allFiles() }
            return .handled
        }
        .onKeyPress(.space) {
            guard let first = cursor.flatMap({ timeline.file(at: $0) }).flatMap({ selection.contains($0.id) ? $0 : nil })
                    ?? selectedFiles.first else { return .ignored }
            model.quickLook(first)
            return .handled
        }
        .onKeyPress(.delete, phases: .down) { press in
            guard press.modifiers.contains(.command), !selection.isEmpty else { return .ignored }
            trashing = selectedFiles
            return .handled
        }
        .task(id: JumpRequest(key: jump, ready: width > 0 && timeline.isLoaded)) {
            guard let key = jump, width > 0, timeline.isLoaded else { return }
            // A month in the Months view may be split into days here: its newest day is where it starts.
            if let index = timeline.sections.firstIndex(where: { $0.key == key || $0.key.containingMonth == key }),
               layout.starts.indices.contains(index) {
                await Task.yield()
                scroll.scrollTo(y: layout.starts[index])
            }
            jump = nil
        }
    }

    private struct JumpRequest: Equatable {
        let key: FileSection.Key?
        let ready: Bool
    }

    private var selectedFiles: [IndexedFile] { selection.compactMap { timeline.known[$0] } }

    /// The pinned header and the rail lie over the scroll view, and a wheel turned over them doesn't reach it, so
    /// it scrolls the timeline from here. A gesture stays with what it began over; a mouse wheel has no gesture, so
    /// each turn decides for itself.
    private func handOnTheWheel() {
        guard wheelMonitor == nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = event.window, window === tracker.hostWindow, let content = window.contentView else { return event }
            if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
                tracker.wheelOverOverlay = isOverOverlay(event.locationInWindow, contentHeight: content.frame.height)
            }
            guard tracker.wheelOverOverlay else { return event }
            scrollBy(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10))
            return nil
        }
        #if DEBUG
        TimelineProbe.overlayWheel = { location, height, delta in
            guard isOverOverlay(location, contentHeight: height) else { return false }
            scrollBy(delta)
            return true
        }
        #endif
    }

    /// Whether `location`, in window coordinates, is over the pinned header or the rail.
    private func isOverOverlay(_ location: NSPoint, contentHeight: CGFloat) -> Bool {
        let point = CGPoint(x: location.x, y: contentHeight - location.y)
        guard frame.contains(point) else { return false }
        let overHeader = tracker.offset > 0.5 && point.y < frame.minY + TimelineMetrics.headerHeight
        return overHeader || (railShown && point.x > frame.maxX - TimelineMetrics.railWidth)
    }

    private func scrollBy(_ delta: Double) {
        scroll.scrollTo(y: min(max(0, tracker.offset - delta), tracker.scrollable))
    }

    // MARK: - Selection

    private func open(_ files: [IndexedFile]) {
        if files.count == 1, timeline.folders.contains(files[0].id) { onOpenFolder(files[0]) } else { model.open(files) }
    }

    /// Where ⇧ extends from, while that file is still where it was.
    private var liveAnchor: Timeline.Position? {
        guard let anchor else { return nil }
        return anchor.position(fileThere: timeline.file(at: anchor.position)?.id, hasSelection: !selection.isEmpty)
    }

    /// Selects what `files` finds, or adds it, unless something newer was chosen while it looked.
    private func selectLater(adding: Bool = false, _ files: @escaping () async -> [IndexedFile]) {
        choices += 1
        let choice = choices
        Task {
            let ids = await files().map(\.id)
            guard choice == choices else { return }
            if adding { selection.formUnion(ids) } else { selection = Set(ids) }
        }
    }

    /// A click at a position, or on nothing. `toggling` is the tick on a picture.
    private func click(_ position: Timeline.Position?, toggling: Bool) {
        focused = true
        choices += 1
        let modifiers = NSEvent.modifierFlags
        guard let position else {
            // On nothing, a click clears the selection; with ⌘ or ⇧ it's a slip, and what was chosen stays.
            if modifiers.isDisjoint(with: [.command, .shift]) { selection = [] }
            return
        }
        guard let file = timeline.file(at: position) else { return }
        if !toggling, NSApp.currentEvent?.clickCount == 2 {
            open([file])
            return
        }
        if toggling || modifiers.contains(.command) {
            if selection.contains(file.id) { selection.remove(file.id) } else { selection.insert(file.id) }
            anchor = GridNavigation.Anchor(position: position, file: file.id)
        } else if modifiers.contains(.shift), let start = liveAnchor {
            selectLater { await timeline.files(from: start, through: position) }
        } else {
            selection = [file.id]
            anchor = GridNavigation.Anchor(position: position, file: file.id)
        }
        cursor = position
    }

    /// Selects all of a section, or deselects it when all of it is selected already.
    private func selectSection(_ section: Int) {
        if let ids = timeline.ids(in: section), !ids.isEmpty, ids.isSubset(of: selection) {
            choices += 1
            selection.subtract(ids)
            return
        }
        selectLater(adding: true) { await timeline.files(in: section) }
    }

    /// Moves the selection with an arrow key, across sections; with Shift, from the anchor to where the keys are now.
    private func move(_ key: KeyEquivalent, extending: Bool, layout: SectionLayout) -> Bool {
        let direction: GridNavigation.Direction = switch key {
        case .leftArrow: .left
        case .rightArrow: .right
        case .upArrow: .up
        default: .down
        }
        guard let next = GridNavigation.next(from: cursor ?? liveAnchor, direction: direction, columns: layout.columns,
                                             counts: layout.counts) else { return false }
        cursor = next
        reveal(next, layout: layout)
        if extending, let start = liveAnchor {
            selectLater { await timeline.files(from: start, through: next) }
        } else {
            choices += 1
            let choice = choices
            Task {
                guard let file = await timeline.file(loadingAt: next), choice == choices else { return }
                selection = [file.id]
                anchor = GridNavigation.Anchor(position: next, file: file.id)
            }
        }
        return true
    }

    /// When the rows change shape, with the window's width or the card size, stays on the same file: every row
    /// above it moved, so the same height would be years away.
    private func keepPlace(from old: SectionLayout, to new: SectionLayout) {
        guard old.counts == new.counts, old != new, tracker.offset > 0, let section = old.section(at: tracker.offset) else { return }
        let row = max(0, Int((tracker.offset - old.starts[section] - old.headerHeight) / old.rowHeight))
        let item = min(row * old.columns, old.counts[section] - 1)
        scroll.scrollTo(y: max(0, new.y(ofItem: item, in: section) - new.headerHeight))
    }

    /// Scrolls just enough to show the row with `position`, below the pinned header.
    private func reveal(_ position: Timeline.Position, layout: SectionLayout) {
        let top = layout.y(ofItem: position.item, in: position.section)
        let bottom = top + layout.rowHeight
        if top < tracker.offset + TimelineMetrics.headerHeight {
            scroll.scrollTo(y: max(0, top - TimelineMetrics.headerHeight))
        } else if bottom > tracker.offset + tracker.viewport {
            scroll.scrollTo(y: bottom - tracker.viewport)
        }
    }
}

/// Tells a view which window it's in.
private struct WindowReader: NSViewRepresentable {
    let onMove: (NSWindow?) -> Void

    final class Reader: NSView {
        var onMove: (NSWindow?) -> Void = { _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onMove(window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ view: Reader, context: Context) {}
}
