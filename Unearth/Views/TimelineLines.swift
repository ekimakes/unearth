import SwiftUI
import UnearthCore

/// The headers and rows of a timeline that fall in `window`, each at its place, on empty space as tall as the
/// whole timeline. Rows are only pictures: clicks land on the whole grid, and hovering, the tick and the right-click
/// menu live on one view that follows the pointer, so a screenful stays light however fast it scrolls. Drawn in a
/// scroll view, or on its own for a snapshot.
struct TimelineLines: View {
    let timeline: Timeline
    let metrics: TimelineMetrics
    let layout: SectionLayout
    let window: Range<Double>
    let kind: FileKind?
    let selection: Set<Int64>
    @Binding var trashing: [IndexedFile]
    /// A click at a position, or on nothing; `true` when it was the tick on a picture.
    var onClick: (Timeline.Position?, Bool) -> Void = { _, _ in }
    var onSelectSection: (Int) -> Void = { _ in }
    /// Whether a height is behind the pinned header: what's there can't be seen, so it can't be clicked.
    var isCovered: (Double) -> Bool = { _ in false }
    @State private var hover = TimelineHover()
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    private struct LoadKey: Equatable {
        let window: Range<Double>
        let loads: Int
        let columns: Int
    }

    private var columnWidth: Double { metrics.itemWidth + metrics.spacing }

    var body: some View {
        let lines = layout.lines(in: window)
        // The rows lie over the empty space rather than sizing it: their width must not hold the window open.
        Color.clear
            .frame(height: layout.height)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(lines, id: \.line) { placed in
                        line(placed.line).offset(y: placed.y)
                    }
                    TimelinePointer(timeline: timeline, hover: hover, metrics: metrics, layout: layout, selection: selection,
                                    trashing: $trashing, onTick: { onClick($0, true) })
                }
            }
            .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { point in
            guard !isCovered(point.y) else { return }
            onClick(layout.position(x: point.x, y: point.y, columnWidth: columnWidth), false)
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                hover.move(to: isCovered(point.y) ? nil : layout.position(x: point.x, y: point.y, columnWidth: columnWidth))
            case .ended:
                hover.move(to: nil)
            }
        }
        .task(id: LoadKey(window: window, loads: timeline.loads, columns: layout.columns)) { request(lines) }
        #if DEBUG
        .onAppear { TimelineProbe.hover = hover }
        #endif
    }

    @ViewBuilder
    private func line(_ line: SectionLayout.Line) -> some View {
        switch line {
        case .header(let section):
            if timeline.sections.indices.contains(section) {
                TimelineHeader(timeline: timeline, section: section, kind: kind, selection: selection) {
                    onSelectSection(section)
                }
            }
        case .row(let section, let row):
            TimelineRow(timeline: timeline, loads: timeline.loads, metrics: metrics, section: section,
                        items: layout.items(inRow: row, of: section), selection: selection, voiceOver: voiceOver,
                        onActivate: { onClick($0, false) })
                .equatable()
        }
    }

    /// Asks for the files of the rows drawn.
    private func request(_ lines: [SectionLayout.Placed]) {
        for placed in lines {
            if case .row(let section, let row) = placed.line {
                timeline.need(section: section, items: layout.items(inRow: row, of: section))
            }
        }
    }
}

/// Where the pointer is over a timeline. Only `TimelinePointer` reads it, so moving the mouse redraws nothing else.
@MainActor @Observable
final class TimelineHover {
    private(set) var position: Timeline.Position?

    func move(to position: Timeline.Position?) {
        if position != self.position { self.position = position }
    }
}

/// The one live spot on a timeline, on the file under the pointer: its name as a tooltip, its right-click menu and,
/// on a picture, the tick that adds it to the selection without a modifier key.
struct TimelinePointer: View {
    let timeline: Timeline
    let hover: TimelineHover
    let metrics: TimelineMetrics
    let layout: SectionLayout
    let selection: Set<Int64>
    @Binding var trashing: [IndexedFile]
    let onTick: (Timeline.Position) -> Void

    var body: some View {
        if let position = hover.position, position.section < layout.counts.count, let file = timeline.file(at: position) {
            let selected = selection.contains(file.id)
            Color.clear
                .contentShape(Rectangle())
                .overlay(alignment: .topLeading) {
                    if metrics.style == .photos {
                        Button { onTick(position) } label: {
                            TileTick(selected: selected)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(selected ? "Selected" : "Select")
                    }
                }
                .frame(width: metrics.itemWidth, height: metrics.itemHeight)
                .contextMenu { menu(for: file) }
                .help(file.name)
                .offset(x: CGFloat(position.item % layout.columns) * (metrics.itemWidth + metrics.spacing),
                        y: layout.y(ofItem: position.item, in: position.section))
        }
    }

    @ViewBuilder
    private func menu(for file: IndexedFile) -> some View {
        let targets = selection.contains(file.id) ? selection.compactMap { timeline.known[$0] } : [file]
        FileActions(files: targets)
        Divider()
        Button("Move to Trash…") { trashing = targets }
    }
}

/// One row of a timeline. It redraws when its own page of files arrives or its files' selection changes, and not
/// when the timeline scrolls.
struct TimelineRow: View, Equatable {
    let timeline: Timeline
    /// Which load of the timeline this is: after a new one, the same row can hold other files.
    let loads: Int
    let metrics: TimelineMetrics
    let section: Int
    let items: Range<Int>
    let selection: Set<Int64>
    let voiceOver: Bool
    let onActivate: (Timeline.Position) -> Void

    nonisolated static func == (left: TimelineRow, right: TimelineRow) -> Bool {
        left.loads == right.loads && left.section == right.section && left.items == right.items && left.metrics == right.metrics
            && left.selection == right.selection && left.voiceOver == right.voiceOver
    }

    var body: some View {
        HStack(alignment: .top, spacing: metrics.spacing) {
            ForEach(items, id: \.self) { item in
                let position = Timeline.Position(section: section, item: item)
                if voiceOver {
                    cell(position).modifier(TimelineCellAccessibility(file: timeline.file(at: position), selection: selection) {
                        onActivate(position)
                    })
                } else {
                    cell(position)
                }
            }
        }
        .frame(height: metrics.rowHeight, alignment: .top)
    }

    @ViewBuilder
    private func cell(_ position: Timeline.Position) -> some View {
        let file = timeline.file(at: position)
        let selected = file.map { selection.contains($0.id) } ?? false
        let isFolder = file.map { timeline.folders.contains($0.id) } ?? false
        switch metrics.style {
        case .photos:
            if let file, isFolder {
                FolderTile(file: file, side: metrics.itemWidth, selected: selected)
            } else {
                PhotoTile(file: file, side: metrics.itemWidth, thumbnailSide: metrics.thumbnailSide, selected: selected)
            }
        case .cards:
            if let file {
                // Cells belong to places, and a reload can put another file at this one: its picture must not stay.
                FileCard(file: file, side: metrics.thumbnailSide, selected: selected, isFolder: isFolder,
                         detail: detail(file, isFolder: isFolder), fillsHeight: true)
                    .id(file.id)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.surface)
                    .frame(width: metrics.itemWidth, height: metrics.itemHeight)
            }
        case .list:
            if let file {
                FileRow(file: file, selected: selected, isFolder: isFolder, date: file.made)
                    .frame(width: metrics.itemWidth)
                    .id(file.id)
            } else {
                Color.clear.frame(width: metrics.itemWidth, height: metrics.itemHeight)
            }
        }
    }

    /// A file's size and folder; in a section that is a folder, or a folder's listing, just its size.
    private func detail(_ file: IndexedFile, isFolder: Bool) -> String {
        let size = file.bytes > 0 ? ByteFormatting.string(file.bytes) : nil
        if isFolder { return size ?? "Folder" }
        var inOneFolder = timeline.isOneFolder
        if timeline.sections.indices.contains(section), case .folder = timeline.sections[section].key { inOneFolder = true }
        return [size, inOneFolder ? nil : (file.parent as NSString).lastPathComponent].compactMap { $0 }.joined(separator: " · ")
    }
}

/// What VoiceOver gets on each file of a timeline. Added only while VoiceOver is on: otherwise a screenful of
/// labels is drawn for no one, and the size in each one is slow to format.
struct TimelineCellAccessibility: ViewModifier {
    @Environment(AppModel.self) private var model
    let file: IndexedFile?
    let selection: Set<Int64>
    let onActivate: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(file.map { "\($0.name), \(ByteFormatting.string($0.bytes))" } ?? "Loading")
            .accessibilityAddTraits(file.map { selection.contains($0.id) } == true ? [.isSelected, .isButton] : .isButton)
            .accessibilityAction(.default, onActivate)
            .accessibilityActions {
                if let file {
                    Button("Open") { model.open([file]) }
                    Button("Quick Look") { model.quickLook(file) }
                }
            }
    }
}
