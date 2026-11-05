import AppKit
import SwiftUI
import UnearthCore

// MARK: - Cards

/// A card on the canvas: the surface color, a 14 pt corner and a hairline rather than a shadow.
struct GalleryCard: ViewModifier {
    var radius: CGFloat = 14
    var fill: Color = .surface
    var line: Color = .hairline

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(line) }
    }
}

extension View {
    func galleryCard(radius: CGFloat = 14, fill: Color = .surface, line: Color = .hairline) -> some View {
        modifier(GalleryCard(radius: radius, fill: fill, line: line))
    }
}

/// A part of a screen: its title, and a link to the full screen when there's more.
struct SectionHeader: View {
    let title: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondaryInk)
            }
        }
    }
}

// MARK: - Thumbnails

/// A file's thumbnail filling whatever space it's given, cropped to fit. `side` is the size it's made at.
/// Pictures, videos and sounds without one get a tinted stand-in; iCloud-only files never get one made,
/// since that would download them.
struct ThumbnailFill: View {
    let file: IndexedFile
    let side: CGFloat
    @State private var image: NSImage?

    init(file: IndexedFile, side: CGFloat) {
        self.file = file
        self.side = side
        _image = State(initialValue: ThumbnailCache.shared.cached(file.path, side: side))
    }

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if KindPlaceholder.covers(file.kind) {
                    KindPlaceholder(kind: file.kind)
                } else {
                    GeometryReader { proxy in
                        Image(nsImage: ThumbnailCache.shared.icon(for: file))
                            .resizable()
                            .scaledToFit()
                            .padding(min(proxy.size.width, proxy.size.height) * 0.14)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
            }
            .clipped()
            .task(id: file.path) {
                guard image == nil, !file.isCloudOnly else { return }
                let made = await ThumbnailCache.shared.image(for: file.path, side: side)
                guard !Task.isCancelled else { return }
                image = made
            }
    }
}

/// A tinted stand-in for a picture, video or sound that has no thumbnail, and for archives.
struct KindPlaceholder: View {
    let kind: FileKind

    static func covers(_ kind: FileKind) -> Bool {
        [.image, .screenshot, .video, .audio, .archive].contains(kind)
    }

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(colors: [kind.color.opacity(0.95), kind.color.opacity(0.6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    Image(systemName: Self.glyph(kind))
                        .font(.system(size: min(proxy.size.width, proxy.size.height) * 0.32, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
        }
    }

    private static func glyph(_ kind: FileKind) -> String {
        switch kind {
        case .video: "play.fill"
        case .audio: "music.note"
        default: kind.symbol
        }
    }
}

/// What a pile shows: a file's thumbnail, an app's icon, or a symbol on a tint.
enum PileThumbnail {
    case file(IndexedFile)
    case icon(NSImage)
    case symbol(String, Color)
}

// MARK: - Piles

/// A clean-up collection as a little pile of its own files, fanned behind its size. The pile spreads a
/// little under the pointer.
struct PileView: View {
    static let thumbnailSide: CGFloat = 46
    /// Piles on the Clean up overview are bigger.
    static let largeThumbnailSide: CGFloat = 64

    let items: [PileThumbnail]
    let title: String
    let bytes: Int64
    let detail: String
    var highlighted = false
    var large = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(items: [PileThumbnail], title: String, bytes: Int64, detail: String, highlighted: Bool = false, large: Bool = false) {
        self.items = items
        self.title = title
        self.bytes = bytes
        self.detail = detail
        self.highlighted = highlighted
        self.large = large
    }

    init(files: [IndexedFile], title: String, bytes: Int64, detail: String, highlighted: Bool = false, large: Bool = false) {
        self.init(items: files.prefix(3).map(PileThumbnail.file), title: title, bytes: bytes, detail: detail,
                  highlighted: highlighted, large: large)
    }

    private var side: CGFloat { large ? Self.largeThumbnailSide : Self.thumbnailSide }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            stack
                .frame(height: side + 8, alignment: .topLeading)
                .padding(.bottom, large ? 14 : 9)
            Text(title)
                .font(.system(size: large ? 13 : 12, weight: large ? .medium : .regular))
                .foregroundStyle(Color.secondaryInk)
                .lineLimit(1)
            Text(ByteFormatting.string(bytes))
                .font(.size(large ? 28 : 22, weight: .bold))
                .foregroundStyle(highlighted ? Color.unearth : Color.ink)
            Text(detail)
                .font(.system(size: large ? 12 : 11))
                .foregroundStyle(Color.secondaryInk)
                .lineLimit(2, reservesSpace: true)
        }
        .padding(large ? EdgeInsets(top: 16, leading: 16, bottom: 15, trailing: 16) : EdgeInsets(top: 12, leading: 12, bottom: 11, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .galleryCard(fill: highlighted ? .hotFill : .surface, line: highlighted ? .hotLine : .hairline)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(ByteFormatting.string(bytes)), \(detail)")
    }

    private var stack: some View {
        let spread = hovering && !reduceMotion
        let angles: [Double] = spread ? [-13, 2, 14] : [-9, 2, 10]
        let scale = side / Self.thumbnailSide
        let offsets: [CGFloat] = (spread ? [0, 30, 60] : [6, 30, 54]).map { $0 * scale }
        let shown = items.isEmpty ? [PileThumbnail.symbol("tray", .secondaryInk)] : Array(items.prefix(3))
        return ZStack(alignment: .topLeading) {
            ForEach(shown.indices, id: \.self) { index in
                thumbnail(shown[index])
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white, lineWidth: 2) }
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                    .rotationEffect(.degrees(angles[index]))
                    .offset(x: offsets[index], y: 4)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: hovering)
    }

    @ViewBuilder
    private func thumbnail(_ item: PileThumbnail) -> some View {
        switch item {
        case .file(let file):
            ThumbnailFill(file: file, side: side)
                .background(Color.surface)
        case .icon(let image):
            Image(nsImage: image).resizable().scaledToFit().padding(4).background(Color.surface)
        case .symbol(let name, let color):
            Image(systemName: name)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(color.opacity(0.14))
                .background(Color.surface)
        }
    }
}

// MARK: - Library tiles

/// One kind of file, filled edge to edge with its newest files under a caption. Documents, archives and
/// apps show pages and icons on their kind's tint instead. The tile lifts a little under the pointer.
struct MosaicTile: View {
    static let height: CGFloat = 132
    /// The size thumbnails are made at, whatever the tile's width.
    static let thumbnailSide: CGFloat = 160

    let kind: FileKind
    let files: [IndexedFile]
    let count: Int
    let bytes: Int64
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Kinds whose thumbnails are pages or icons rather than pictures.
    static func isSoft(_ kind: FileKind) -> Bool {
        [.document, .archive, .app, .other].contains(kind)
    }

    var body: some View {
        let soft = Self.isSoft(kind)
        ZStack(alignment: .bottomLeading) {
            if kind == .app {
                icons
            } else if soft {
                pages
            } else {
                pictures
            }
            caption(soft: soft)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(kind.color.opacity(soft ? 0.12 : 0.22))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline) }
        .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)
        .shadow(color: .black.opacity(hovering ? 0.14 : 0), radius: 10, y: 5)
        .animation(reduceMotion ? nil : .spring(duration: 0.25), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.title), \(count == 1 ? "1 file" : "\(count.formatted()) files"), \(ByteFormatting.string(bytes))")
    }

    private var pictures: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) { picture(0); picture(1) }
            HStack(spacing: 2) { picture(2); picture(3) }
        }
    }

    @ViewBuilder
    private func picture(_ index: Int) -> some View {
        if index < files.count, kind == .audio {
            // Sounds rarely have a picture worth showing; a tint per cell keeps the tile lively.
            KindPlaceholder(kind: kind).hueRotation(.degrees(Double(index) * 24 - 24))
        } else if index < files.count {
            ThumbnailFill(file: files[index], side: Self.thumbnailSide)
        } else {
            kind.color.opacity(0.18)
        }
    }

    /// Documents and archives as a row of pages on the kind's tint, above the caption.
    private var pages: some View {
        HStack(spacing: 6) { page(0); page(1); page(2) }
            .frame(height: 74)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func page(_ index: Int) -> some View {
        Group {
            if index < files.count, kind == .archive {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(kind.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if index < files.count {
                ThumbnailFill(file: files[index], side: Self.thumbnailSide)
            } else {
                Color.clear
            }
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.hairline) }
        .opacity(index < files.count ? 1 : 0.5)
    }

    /// Apps as their icons, three by two.
    private var icons: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(files.prefix(6)) { file in
                Image(nsImage: ThumbnailCache.shared.icon(for: file))
                    .resizable()
                    .scaledToFit()
                    .frame(height: 34)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func caption(soft: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(kind.title).font(.system(size: 13, weight: .semibold))
            Text("\(count.formatted()) · \(ByteFormatting.string(bytes))")
                .font(.size(11, weight: .medium))
                .opacity(0.85)
        }
        .foregroundStyle(soft ? Color.ink : .white)
        .padding(EdgeInsets(top: 22, leading: 10, bottom: 8, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(
            colors: soft ? [Color.surface.opacity(0), Color.surface.opacity(0.94)] : [.clear, .black.opacity(0.62)],
            startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - Monograms

/// A download source's logo, shipped with the app so showing it needs no network. A website Unearth doesn't
/// recognize gets its initial in a color of its own.
struct Monogram: View {
    let name: String
    var side: CGFloat = 28

    var body: some View {
        Group {
            if let logo = DownloadSource.logo(for: name) {
                Image("Logos/\(logo)")
                    .resizable()
                    .scaledToFit()
                    .padding(side * (side < 20 ? 0.12 : 0.2))
                    .frame(width: side, height: side)
                    // Logos are drawn for white, so they get it in dark mode too.
                    .background(.white, in: Circle())
                    .overlay { Circle().strokeBorder(Color.black.opacity(0.08)) }
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: side * 0.46, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: side, height: side)
                    .background(Self.color(for: name), in: Circle())
            }
        }
        .accessibilityHidden(true)
    }

    private static let palette: [UInt32] = [
        0x2E90FA, 0x7A5AF8, 0x12B76A, 0xEE46BC, 0xF79009, 0x06AED4, 0x6172F3, 0xF04438, 0x0E9384,
    ]

    /// The same color for a website every time, on every Mac.
    static func color(for name: String) -> Color {
        Color(hex: palette[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count])
    }
}

// MARK: - Figures

/// A size that counts up once, the first time it appears for `id` (a scan), unless Reduce Motion is on.
struct CountUpSize: View {
    let bytes: Int64
    var size: CGFloat = 34
    var weight: Font.Weight = .bold
    var id: AnyHashable?
    @State private var shown: Int64?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @MainActor private static var played: Set<AnyHashable> = []

    var body: some View {
        Text(ByteFormatting.string(shown ?? bytes))
            .font(.size(size, weight: weight))
            .accessibilityLabel(ByteFormatting.string(bytes))
            .task(id: id) {
                guard let id, !reduceMotion, bytes > 0, !Self.played.contains(id) else { return }
                Self.played.insert(id)
                let steps = 30
                for step in 0...steps {
                    let progress = Double(step) / Double(steps)
                    let eased = 1 - pow(1 - progress, 3)
                    shown = Int64(Double(bytes) * eased)
                    try? await Task.sleep(for: .milliseconds(28))
                }
                shown = nil
            }
    }
}
