import SwiftUI
import UnearthCore

/// The ways to look at a timeline: a tile a year, a month, or a folder or source, or every file.
enum TimelineZoom: Hashable {
    case years, months, overview, all

    /// What a screen opens at: a screen of many files in folders or sources opens at its overview, so all of it
    /// is in sight at once.
    static func opening(_ grouping: FileGrouping, count: Int) -> TimelineZoom {
        grouping == .date || count < PlaceListing.manyFiles ? .all : .overview
    }

    /// This zoom where the grouping has it, for a grouping just changed.
    func fitted(to grouping: FileGrouping) -> TimelineZoom {
        switch self {
        case .overview where grouping == .date: .all
        case .years where grouping != .date, .months where grouping != .date: .overview
        default: self
        }
    }

    /// What the switch and the Back button call this zoom.
    func title(for grouping: FileGrouping) -> String {
        switch self {
        case .years: "Years"
        case .months: "Months"
        case .overview: grouping == .folder ? "Folders" : "Sources"
        case .all: "All"
        }
    }
}

/// The switch between the zooms a grouping has, with how many of each.
struct TimelineZoomPills: View {
    @Binding var zoom: TimelineZoom
    let timeline: Timeline
    let grouping: FileGrouping

    var body: some View {
        let tabs: [(tab: TimelineZoom, title: String, count: Int)] = if grouping == .date {
            [(.years, timeline.years.count), (.months, timeline.years.reduce(0) { $0 + $1.months.count }), (.all, timeline.count)]
                .map { ($0, $0.title(for: grouping), $1) }
        } else {
            [(.overview, timeline.sections.count), (.all, timeline.count)].map { ($0, $0.title(for: grouping), $1) }
        }
        TabPills(selection: $zoom, tabs: tabs)
    }
}

/// A timeline as a screen shows it: every file, or with months, the Years or the Months view. Clicking a year
/// opens the Months view there, and clicking a month opens every file there.
struct TimelineScreen: View {
    let timeline: Timeline
    @Binding var zoom: TimelineZoom
    let style: TimelineStyle
    let kind: FileKind?
    let grouping: FileGrouping
    @Binding var selection: Set<Int64>
    @Binding var trashing: [IndexedFile]
    /// The tiles opened to get here, for the screen's Back button.
    @Binding var trail: BackTrail<TimelineZoom>
    var onOpenFolder: (IndexedFile) -> Void = { _ in }
    @State private var monthsYear: Int?
    @State private var jump: FileSection.Key?
    /// The folder or source opened last: coming back lands on its tile.
    @State private var openedTile: FileSection.ID?

    var body: some View {
        screen.onChange(of: zoom) { trail.arrived(at: zoom) }
    }

    @ViewBuilder private var screen: some View {
        switch zoom.fitted(to: grouping) {
        case .overview:
            ScrollViewReader { proxy in
                ScrollView {
                    TimelineOverviewContent(timeline: timeline, kind: kind, selection: $selection) { section in
                        openedTile = section.id
                        jump = section.key
                        open(.all)
                    }
                }
                .onAppear {
                    if let openedTile { proxy.scrollTo(openedTile, anchor: .center) }
                }
            }
        case .years:
            ScrollView {
                TimelineYearsContent(timeline: timeline, kind: kind) { year in
                    monthsYear = year.year
                    open(.months)
                }
            }
        case .months:
            TimelineMonths(timeline: timeline, kind: kind, year: monthsYear) { month in
                jump = month.key
                open(.all)
            }
        case .all:
            TimelineGrid(timeline: timeline, style: style, kind: kind, showsRail: grouping == .date, selection: $selection,
                         trashing: $trashing, jump: $jump, onOpenFolder: onOpenFolder)
        }
    }

    private func open(_ next: TimelineZoom) {
        trail.entered(from: zoom.fitted(to: grouping))
        zoom = next
    }
}

/// A timeline a year at a time: each year a tile of its pictures, with how many files and how much space.
struct TimelineYearsContent: View {
    let timeline: Timeline
    let kind: FileKind?
    var onOpen: (FileYear) -> Void = { _ in }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: 16)], spacing: 16) {
            ForEach(timeline.years) { year in
                Button { onOpen(year) } label: { YearTile(timeline: timeline, year: year, kind: kind) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, TimelineMetrics.padding)
        .padding(.top, 4)
        .padding(.bottom, TimelineMetrics.padding)
    }
}

/// A screen's folders or download sources, a tile each, the one with the most files first: all of it in sight
/// without scrolling through its files. Ticking tiles selects all their files, so several can go at once.
struct TimelineOverviewContent: View {
    let timeline: Timeline
    let kind: FileKind?
    var selection: Binding<Set<Int64>> = .constant([])
    var onOpen: (FileSection) -> Void = { _ in }
    /// Tiles ticked whose files are still on their way.
    @State private var arriving: Set<FileSection.Key> = []

    var body: some View {
        let picking = !selection.wrappedValue.isEmpty || !arriving.isEmpty
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: 16)], spacing: 16) {
            ForEach(Array(timeline.sections.enumerated()), id: \.element.id) { index, section in
                PickableSectionTile(timeline: timeline, index: index, section: section, kind: kind,
                                    coverage: coverage(index, section), picking: picking,
                                    onTick: { tick(index, section) }, onOpen: { onOpen(section) })
            }
        }
        .padding(.horizontal, TimelineMetrics.padding)
        .padding(.top, 4)
        .padding(.bottom, TimelineMetrics.padding)
        #if DEBUG
        .onAppear {
            TimelineProbe.overviewTimeline = timeline
            TimelineProbe.overviewSelection = { selection.wrappedValue }
            TimelineProbe.clearOverviewSelection = { selection.wrappedValue = [] }
        }
        #endif
    }

    private func coverage(_ index: Int, _ section: FileSection) -> SectionCoverage {
        if arriving.contains(section.key) { return .whole }
        return timeline.ids(in: index).map { SectionCoverage(of: $0, in: selection.wrappedValue) } ?? .nothing
    }

    /// Selects all of a tile's files, or deselects them when all of them are selected already. Every tile ticked
    /// in a row counts, however long each one's files take to load.
    private func tick(_ index: Int, _ section: FileSection) {
        guard !arriving.contains(section.key) else {
            arriving.remove(section.key)
            return
        }
        if let ids = timeline.ids(in: index), SectionCoverage(of: ids, in: selection.wrappedValue) == .whole {
            selection.wrappedValue.subtract(ids)
            return
        }
        arriving.insert(section.key)
        Task {
            let files = await timeline.files(in: index)
            guard arriving.remove(section.key) != nil else { return }
            selection.wrappedValue.formUnion(files.map(\.id))
        }
    }
}

/// A folder or source tile with a tick in its corner. The tick shows on hover and, once anything is selected, on
/// every tile. While selecting, a click anywhere on a tile ticks it instead of opening it.
private struct PickableSectionTile: View {
    let timeline: Timeline
    let index: Int
    let section: FileSection
    let kind: FileKind?
    let coverage: SectionCoverage
    let picking: Bool
    let onTick: () -> Void
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        let title = section.key.title(calendar: timeline.calendar)
        Button(action: picking ? onTick : onOpen) {
            SectionTile(timeline: timeline, section: section, kind: kind, picked: coverage != .nothing)
        }
        .buttonStyle(.plain)
        .accessibilityAction(named: coverage == .whole ? "Deselect" : "Select", onTick)
        .overlay(alignment: .topLeading) {
            // Always there, so a click in the corner ticks even when the hover hasn't caught up with the pointer.
            Button(action: onTick) {
                TileTick(selected: coverage == .whole, partly: coverage == .part, side: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(picking || hovering ? 1 : 0.001)
            .help(coverage == .whole ? "Deselect \(title)" : "Select \(title)")
            .accessibilityHidden(true)
        }
        .onHover { hovering = $0 }
        // Whether the tile is ticked, however its files came to be selected.
        .task(id: timeline.loads) { timeline.needIDs(in: index) }
        #if DEBUG
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { TimelineProbe.tiles[index] = $0 }
        #endif
    }
}

/// A timeline a month at a time, under each year's name.
struct TimelineMonthsContent: View {
    let timeline: Timeline
    let kind: FileKind?
    var onOpen: (FileSection) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(timeline.years) { year in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(String(year.year))
                            .font(.size(22, weight: .bold))
                            .foregroundStyle(Color.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text("\(FileKind.count(year.count, of: kind)) · \(ByteFormatting.string(year.bytes))")
                            .font(.size(12, weight: .medium))
                            .foregroundStyle(Color.secondaryInk)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 250), spacing: 12)], spacing: 12) {
                        ForEach(year.months) { month in
                            Button { onOpen(month) } label: { MonthTile(timeline: timeline, month: month, kind: kind) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .id(year.year)
            }
        }
        .padding(.horizontal, TimelineMetrics.padding)
        .padding(.top, 4)
        .padding(.bottom, TimelineMetrics.padding)
    }
}

/// The Months view, scrolled to a year chosen in the Years view.
struct TimelineMonths: View {
    let timeline: Timeline
    let kind: FileKind?
    let year: Int?
    let onOpen: (FileSection) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                TimelineMonthsContent(timeline: timeline, kind: kind, onOpen: onOpen)
            }
            .onAppear {
                if let year { proxy.scrollTo(year, anchor: .top) }
            }
        }
    }
}

/// One big picture and two small ones, under a title and what the pictures come from.
struct PictureTile: View {
    static let thumbnailSide: CGFloat = 240
    let files: [IndexedFile]
    let title: String
    var titleSize: CGFloat = 30
    var place: String?
    let detail: String
    /// Ticked: some or all of what it stands for is selected.
    var picked = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    picture(0).frame(width: (proxy.size.width * 0.64).rounded())
                    VStack(spacing: 2) {
                        picture(1)
                        picture(2)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.size(titleSize, weight: .heavy))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let place {
                    Text(place)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .opacity(0.8)
                }
                Text(detail)
                    .font(.size(12, weight: .medium))
                    .lineLimit(1)
                    .opacity(0.88)
            }
            .foregroundStyle(.white)
            .padding(EdgeInsets(top: 40, leading: 14, bottom: 12, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.66)], startPoint: .top, endPoint: .bottom))
        }
        .frame(height: 196)
        .background(Color.hairline.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(picked ? Color.unearth : Color.hairline, lineWidth: picked ? 3 : 1)
        }
        .scaleEffect(hovering && !reduceMotion ? 1.015 : 1)
        .shadow(color: .black.opacity(hovering ? 0.14 : 0), radius: 10, y: 5)
        .animation(reduceMotion ? nil : .spring(duration: 0.25), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, place, detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func picture(_ index: Int) -> some View {
        if index < files.count {
            Color.clear
                .overlay { TileThumbnail(file: files[index], side: Self.thumbnailSide).id(files[index].id) }
                .clipped()
        } else {
            Color.hairline.opacity(0.45)
        }
    }
}

/// A year: pictures from across it, its number and what it holds.
struct YearTile: View {
    let timeline: Timeline
    let year: FileYear
    let kind: FileKind?
    @State private var files: [IndexedFile]

    init(timeline: Timeline, year: FileYear, kind: FileKind?) {
        self.timeline = timeline
        self.year = year
        self.kind = kind
        _files = State(initialValue: timeline.cachedPreviews(of: year))
    }

    var body: some View {
        PictureTile(files: files, title: String(year.year),
                    detail: "\(FileKind.count(year.count, of: kind)) · \(ByteFormatting.string(year.bytes))")
            .task(id: timeline.loads) { files = await timeline.previews(of: year, count: 3) }
    }
}

/// A folder or a download source: pictures from across it, its name, where it is and what it holds.
struct SectionTile: View {
    let timeline: Timeline
    let section: FileSection
    let kind: FileKind?
    var picked = false
    @State private var files: [IndexedFile]

    init(timeline: Timeline, section: FileSection, kind: FileKind?, picked: Bool = false) {
        self.timeline = timeline
        self.section = section
        self.kind = kind
        self.picked = picked
        _files = State(initialValue: timeline.cachedPreviews(of: section))
    }

    var body: some View {
        PictureTile(files: files, title: section.key.title(calendar: timeline.calendar), titleSize: 17, place: section.key.place,
                    detail: "\(FileKind.count(section.count, of: kind)) · \(ByteFormatting.string(section.bytes))", picked: picked)
            .task(id: timeline.loads) { files = await timeline.previews(of: section, count: 3) }
    }
}

/// A month: a picture from the middle of it, its name and how many files.
struct MonthTile: View {
    static let thumbnailSide: CGFloat = 240
    let timeline: Timeline
    let month: FileSection
    let kind: FileKind?
    @State private var file: IndexedFile?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(timeline: Timeline, month: FileSection, kind: FileKind?) {
        self.timeline = timeline
        self.month = month
        self.kind = kind
        _file = State(initialValue: timeline.cachedPreviews(of: month).first)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .overlay {
                    if let file {
                        TileThumbnail(file: file, side: Self.thumbnailSide).id(file.id)
                    } else {
                        Color.hairline.opacity(0.45)
                    }
                }
                .clipped()
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.size(15, weight: .bold))
                Text("\(month.count.formatted()) · \(ByteFormatting.string(month.bytes))")
                    .font(.size(11, weight: .medium))
                    .opacity(0.88)
            }
            .foregroundStyle(.white)
            .padding(EdgeInsets(top: 28, leading: 10, bottom: 9, trailing: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline) }
        .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)
        .shadow(color: .black.opacity(hovering ? 0.14 : 0), radius: 8, y: 4)
        .animation(reduceMotion ? nil : .spring(duration: 0.25), value: hovering)
        .onHover { hovering = $0 }
        .task(id: timeline.loads) { file = await timeline.previews(of: month, count: 1).first }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(month.key.title(calendar: timeline.calendar)), \(FileKind.count(month.count, of: kind)), \(ByteFormatting.string(month.bytes))")
        .accessibilityAddTraits(.isButton)
    }

    /// "October": the year is in the heading above.
    private var name: String {
        guard case .month(let year, let number) = month.key,
              let date = timeline.calendar.date(from: DateComponents(year: year, month: number, day: 15)) else { return "" }
        return date.formatted(Date.FormatStyle(calendar: timeline.calendar, timeZone: timeline.calendar.timeZone).month(.wide))
    }
}
