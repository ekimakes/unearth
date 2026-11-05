import AppKit
import SwiftUI
import UnearthCore

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var reviewing = false

    var body: some View {
        ScrollView {
            HomeContent(onReview: { reviewing = true })
        }
        .background(Color.canvas)
        .sheet(isPresented: $reviewing) {
            ReviewSheet(itemIDs: model.plan?.defaultSelection() ?? [])
        }
    }
}

/// Home without its scroll view, so it can also be rendered to an image.
struct HomeContent: View {
    static let mosaicSide: CGFloat = 52
    static let recentSide: CGFloat = 112
    static let examples = ["screenshots with invoice", "videos over 1 GB", "pdfs from last week", "from ChatGPT"]
    /// Piles on Home: the safe-to-free plan, then the biggest collections. The rest are in Clean up.
    static let pilesShown = 5

    @Environment(AppModel.self) private var model
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            search
            hero
            library
            worthALook
            if !model.library.sources.isEmpty { downloadedFrom }
            if !model.library.recent.isEmpty { recentlyAdded }
        }
        .padding(EdgeInsets(top: 22, leading: 28, bottom: 32, trailing: 28))
        .frame(maxWidth: 1_160, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Search

    private var search: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { model.requestSearchFocus() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.secondaryInk)
                    Text("Search your files by name, or by what's in them")
                        .foregroundStyle(Color.secondaryInk)
                    Spacer()
                    Text("⌘K")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.secondaryInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.hairline) }
                }
                .font(.system(size: 14))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .contentShape(Rectangle())
                .galleryCard(radius: 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search your files")
            HStack(spacing: 8) {
                Text("Try").foregroundStyle(Color.secondaryInk)
                ForEach(Self.examples, id: \.self) { example in
                    Button(example) { model.search(example) }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .galleryCard(radius: 12)
                }
            }
            .font(.system(size: 12))
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 26) {
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.greeting(for: Date()))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color.ink)
                    .padding(.bottom, 4)
                Text(summary)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Color.secondaryInk)
                    .padding(.bottom, 14)
                StorageBand(segments: bandSegments)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            freeCard
        }
    }

    static func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    private var summary: String {
        let files = model.library.kinds.reduce(0) { $0 + $1.count }
        var parts: [String] = []
        if files > 0 { parts.append(files == 1 ? "1 file in your Library" : "\(files.formatted()) files in your Library") }
        if let volumes = model.volumes {
            parts.append("\(ByteFormatting.string(volumes.used)) of \(ByteFormatting.string(volumes.container.capacity)) used")
        }
        if model.isRefreshing { parts.append("Checking your disk") }
        return parts.isEmpty ? "Measuring your disk" : parts.joined(separator: " · ")
    }

    private var bandSegments: [StorageBar.Segment] {
        if let breakdown = model.breakdown { return StorageBar.segments(for: breakdown) }
        if let volumes = model.volumes { return StorageBar.segments(for: volumes) }
        return []
    }

    /// The dark card: how much can safely go, and the way to it.
    private var freeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .scanning(let progress) = model.phase {
                Text("Measuring your disk")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                Text(progress.files == 0 ? "Just a moment" : "\(progress.files.formatted()) files so far")
                    .font(.size(17, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 8)
                ProgressView().progressViewStyle(.linear).tint(.unearth)
            } else {
                Text("You can safely free")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                CountUpSize(bytes: model.safeToFree, size: 34, weight: .bold, id: model.tree?.id)
                    .foregroundStyle(.white)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
                Button(action: onReview) {
                    Text("Review & clean")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.unearth, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(model.safeToFree == 0)
                .opacity(model.safeToFree == 0 ? 0.5 : 1)
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(width: 250, alignment: .leading)
        .background(Color.dynamic(light: 0x15171C, dark: 0x2A2E36), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Library

    private var library: some View {
        let library = model.library
        let kinds = SidebarItem.libraryKinds.filter { library.count(of: $0) > 0 }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Your Library", action: kinds.isEmpty ? nil : ("Browse all", { model.sidebarSelection = .recents }))
            if kinds.isEmpty {
                Text(libraryStatus)
                    .foregroundStyle(Color.secondaryInk)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .galleryCard()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12)], spacing: 12) {
                    ForEach(kinds, id: \.self) { kind in
                        Button { model.sidebarSelection = .kind(kind) } label: {
                            MosaicTile(kind: kind, files: library.newest[kind] ?? [], count: library.count(of: kind),
                                       bytes: library.bytes(of: kind))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var libraryStatus: String {
        switch model.library.status {
        case .indexing(let files): "Building your Library: \(files.formatted()) files so far."
        case .unavailable: "The Library couldn't be opened."
        case .idle: "Your Library appears after the first scan."
        default: "No files in your Library folders yet."
        }
    }

    // MARK: - Worth a look

    @ViewBuilder
    private var worthALook: some View {
        let collections = model.collections
        let kinds = Array(CollectionKind.shown(in: collections).prefix(model.safeToFree > 0 ? Self.pilesShown - 1 : Self.pilesShown))
        if model.safeToFree > 0 || !kinds.isEmpty || collections.isWorking {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Worth a look", action: ("See all", { model.sidebarSelection = .cleanUp }))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    if model.safeToFree > 0 {
                        Button(action: onReview) {
                            PileView(items: model.leftoverPileItems, title: "Caches & leftovers", bytes: model.safeToFree,
                                     detail: "Safe to remove, rebuilds itself", highlighted: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Review what's safe to remove")
                    }
                    ForEach(kinds, id: \.self) { kind in
                        let summary = collections.summaries[kind]
                        Button { model.sidebarSelection = .collection(kind) } label: {
                            PileView(items: collections.pileItems(kind), title: kind.title, bytes: summary?.bytes ?? 0,
                                     detail: kind.detail(count: summary?.count ?? 0, settings: collections.settings))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens \(kind.title)")
                    }
                }
                if kinds.isEmpty, collections.isWorking {
                    Text("Looking for duplicates, forgotten downloads and unused apps…")
                        .font(.callout)
                        .foregroundStyle(Color.secondaryInk)
                }
            }
        }
    }

    // MARK: - Downloaded from

    private var downloadedFrom: some View {
        let (big, small) = SourceCard.split(model.library.sources)
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Downloaded from",
                          action: ("See all \(model.library.sources.count)", { model.sidebarSelection = .downloadedFrom }))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                ForEach(big.prefix(5), id: \.source) { source in
                    Button { model.sidebarSelection = .source(source.source) } label: {
                        SourceCard(name: source.source, count: source.count,
                                   previews: model.library.sourcePreviews[source.source] ?? [])
                    }
                    .buttonStyle(.plain)
                }
                if !small.isEmpty {
                    Button { model.sidebarSelection = .downloadedFrom } label: {
                        SourceCard(name: SourceCard.otherWebsites, count: small.reduce(0) { $0 + $1.count }, previews: [])
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Recently added

    private var recentlyAdded: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Recently added", action: ("See all", { model.sidebarSelection = .recents }))
            HStack(alignment: .top, spacing: 14) {
                ForEach(model.library.recent.prefix(6)) { file in
                    VStack(alignment: .leading, spacing: 6) {
                        FileThumbnail(file: file, side: Self.recentSide)
                            .overlay {
                                RoundedRectangle(cornerRadius: max(4, Self.recentSide * 0.06), style: .continuous)
                                    .strokeBorder(Color.hairline)
                            }
                        Text(file.name)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: Self.recentSide, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if NSApp.currentEvent?.clickCount == 2 { model.open([file]) } else { model.quickLook(file) }
                    }
                    .contextMenu { FileActions(files: [file]) }
                    .help(file.name)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Open") { model.open([file]) }
                }
            }
        }
    }
}

/// The storage band in category colors, with a legend that wraps.
struct StorageBand: View {
    let segments: [StorageBar.Segment]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StorageBar(segments: segments, height: 22)
            FlowLayout(spacing: 14, lineSpacing: 4) {
                ForEach(segments.filter { $0.bytes > 0 }) { segment in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(segment.isFree ? Color.freeSpace : segment.color)
                            .overlay { if segment.isFree { Circle().strokeBorder(Color.hairline) } }
                            .frame(width: 8, height: 8)
                        Text("\(segment.name) \(ByteFormatting.string(segment.bytes))")
                            .monospacedDigit()
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.secondaryInk)
                }
            }
        }
    }
}

/// Where downloads came from: the source's monogram, name, how many files, and its newest three.
struct SourceCard: View {
    static let thumbnailSide: CGFloat = 26
    static let otherWebsites = "Other websites"
    /// Sources with fewer files than this share one card.
    static let smallSource = 3

    let name: String
    let count: Int
    var bytes: Int64?
    let previews: [IndexedFile]

    /// The sources big enough for a card of their own, most files first, and the small ones.
    static func split(_ sources: [SourceSummary]) -> (big: [SourceSummary], small: [SourceSummary]) {
        let sorted = sources.sorted { $0.count != $1.count ? $0.count > $1.count : $0.source < $1.source }
        return (sorted.filter { $0.count >= smallSource }, sorted.filter { $0.count < smallSource })
    }

    var body: some View {
        HStack(spacing: 9) {
            if name == Self.otherWebsites {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.secondaryInk, in: Circle())
            } else {
                Monogram(name: name)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Text((count == 1 ? "1 file" : "\(count.formatted()) files") + (bytes.map { ", \(ByteFormatting.string($0))" } ?? ""))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color.secondaryInk)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(previews.prefix(3)) { file in
                    ThumbnailFill(file: file, side: Self.thumbnailSide)
                        .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        }
        .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10))
        .contentShape(Rectangle())
        .galleryCard(radius: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(count == 1 ? "1 file" : "\(count) files")")
    }
}

/// Views in rows that wrap, like words.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += line + lineSpacing
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += line + lineSpacing
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// What can be done with files anywhere in the Library: open, look, find, copy the text in an image or the path.
/// Move to Trash lives on the browse screens, where its confirmation is.
struct FileActions: View {
    @Environment(AppModel.self) private var model
    let files: [IndexedFile]

    var body: some View {
        Button("Open") { model.open(files) }
        Button("Quick Look") { if let first = files.first { model.quickLook(first) } }
        Button("Show in Finder") { model.revealInFinder(files) }
        if files.contains(where: { model.library.textIDs.contains($0.id) }) {
            Button("Copy Text") { Task { await model.copyText(files) } }
        }
        Button(files.count == 1 ? "Copy Path" : "Copy Paths") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
        }
    }
}
