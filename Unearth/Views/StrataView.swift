import SwiftUI
import UnearthCore

/// The disk drawn as layers of earth under a sky of free space. Hovering a layer shows its size; clicking one opens
/// what explains it.
struct StrataView: View {
    static let height: CGFloat = 320
    /// Thin enough to stay honest about small categories, thick enough for a label.
    static let minimumShare = 0.065

    let breakdown: StorageBreakdown
    let safeToFree: Int64
    let onReview: () -> Void
    let onOpen: (StorageCategory) -> Void
    @State private var hovered: StrataLayer?
    @State private var pointer: CGPoint = .zero
    @Environment(\.colorScheme) private var scheme

    private var layers: [StrataLayer] {
        StrataLayout.layers(segments: breakdown.segments, free: breakdown.free, minimumShare: Self.minimumShare)
    }

    var body: some View {
        let layers = self.layers
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    draw(layers, in: &context, size: size)
                }
                ForEach(layers.indices, id: \.self) { index in
                    label(for: layers[index], above: index + 1 < layers.count ? layers[index + 1] : nil, size: size)
                }
                if let hovered {
                    hoverCard(hovered).position(x: min(max(pointer.x, 120), size.width - 120), y: max(pointer.y - 30, 20))
                }
                digOutCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 22)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    pointer = location
                    hovered = layer(at: location, in: layers, size: size)
                case .ended:
                    hovered = nil
                }
            }
            .onTapGesture { location in
                guard let category = layer(at: location, in: layers, size: size)?.category, Self.opens(category) else { return }
                onOpen(category)
            }
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(layers))
        .accessibilityActions {
            ForEach(layers.compactMap(\.category).filter(Self.opens), id: \.self) { category in
                Button("Open \(CategoryStyle.name(category))") { onOpen(category) }
            }
            Button("Review & clean", action: onReview)
        }
    }

    /// macOS is its own sealed volume, with nothing to open.
    static func opens(_ category: StorageCategory) -> Bool { category != .macOS }

    // MARK: - Drawing

    private func draw(_ layers: [StrataLayer], in context: inout GraphicsContext, size: CGSize) {
        let sky = Strata.sky(scheme)
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: [sky.0, sky.1]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        for layer in layers {
            guard let category = layer.category else { continue }
            var fill = Strata.color(category, scheme)
            if hovered == layer { fill = fill.mix(with: .white, by: 0.14) }
            context.fill(surface(layer, size: size), with: .color(fill))
        }
    }

    /// A layer's wavy top edge, closed down to the bottom of the picture for filling.
    private func surface(_ layer: StrataLayer, size: CGSize) -> Path {
        let points = edge(layer, size: size)
        var path = Path()
        path.move(to: points[0])
        for index in 1..<points.count {
            let previous = points[index - 1], point = points[index]
            path.addQuadCurve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), control: previous)
        }
        path.addLine(to: points[points.count - 1])
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }

    private func edge(_ layer: StrataLayer, size: CGSize) -> [CGPoint] {
        let wave = StrataLayout.wave(for: layer)
        return wave.indices.map { index in
            CGPoint(x: size.width * CGFloat(index) / CGFloat(wave.count - 1), y: (layer.top + wave[index]) * size.height)
        }
    }

    /// Where a layer's top edge is at `x`.
    private func top(of layer: StrataLayer, at x: CGFloat, size: CGSize) -> CGFloat {
        guard layer.top > 0 else { return 0 }
        let wave = StrataLayout.wave(for: layer)
        let position = max(0, min(1, x / max(size.width, 1))) * CGFloat(wave.count - 1)
        let index = min(Int(position), wave.count - 2)
        let offset = wave[index] + (wave[index + 1] - wave[index]) * Double(position - CGFloat(index))
        return (layer.top + offset) * size.height
    }

    private func layer(at point: CGPoint, in layers: [StrataLayer], size: CGSize) -> StrataLayer? {
        layers.last { top(of: $0, at: point.x, size: size) <= point.y }
    }

    // MARK: - Labels and cards

    /// A specimen label at the left of each layer that's tall enough for one, centred between its wavy edges.
    @ViewBuilder
    private func label(for layer: StrataLayer, above next: StrataLayer?, size: CGSize) -> some View {
        let top = top(of: layer, at: 60, size: size)
        let bottom = next.map { self.top(of: $0, at: 60, size: size) } ?? size.height
        if bottom - top >= 15 {
            HStack(spacing: 6) {
                Text(layer.category.map(CategoryStyle.name) ?? "Free")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text(ByteFormatting.string(layer.bytes))
                    .font(.system(size: 12, design: .monospaced))
                    .opacity(0.75)
            }
            .foregroundStyle(darkLabel(layer) ? Color(hex: 0x15171C).opacity(0.82) : .white.opacity(0.94))
            .shadow(color: .black.opacity(darkLabel(layer) ? 0 : 0.4), radius: 1.5, y: 1)
            .fixedSize()
            .offset(x: 18, y: (top + bottom) / 2 - 8)
            .allowsHitTesting(false)
        }
    }

    /// Light layers (the daylight sky, sandstone, ochre) take dark labels.
    private func darkLabel(_ layer: StrataLayer) -> Bool {
        guard scheme == .light else { return false }
        return layer.category.map { Strata.luminance(Strata.hex($0, scheme)) > 0.62 } ?? true
    }

    private func hoverCard(_ layer: StrataLayer) -> some View {
        let name = layer.category.map(CategoryStyle.name) ?? "Free space"
        let whole = layer.category == nil ? breakdown.total : breakdown.used
        let share = whole > 0 ? Double(layer.bytes) / Double(whole) : 0
        let note = layer.category == .macOS ? "macOS itself, on its own sealed volume"
            : layer.category == nil ? "\(share.formatted(.percent.precision(.fractionLength(0)))) of your disk"
            : "\(share.formatted(.percent.precision(.fractionLength(0)))) of what's used"
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(name) \(ByteFormatting.string(layer.bytes))").font(.system(size: 12, weight: .semibold))
            Text(note).font(.system(size: 11)).opacity(0.75)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(.white)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
        .allowsHitTesting(false)
    }

    /// "Safe to dig out": what Unearth can free, and the way to it.
    private var digOutCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Safe to dig out")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(hex: 0xFFB37A))
            Text(ByteFormatting.string(safeToFree))
                .font(.size(34, weight: .bold))
                .foregroundStyle(Color.unearth)
                .padding(.vertical, 2)
            Text("Caches and build files that rebuild themselves.")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0xC9B9A8))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            Button(action: onReview) {
                Text("Review & clean")
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.unearth, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .foregroundStyle(Color(hex: 0x1A120B))
            }
            .buttonStyle(.plain)
            .disabled(safeToFree == 0)
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(width: 236, alignment: .leading)
        .background(Color(hex: 0x17130F).opacity(0.82), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.unearth.opacity(0.45))
        }
        .shadow(color: Color.unearth.opacity(0.22), radius: 20)
    }

    private func accessibilitySummary(_ layers: [StrataLayer]) -> String {
        let parts = layers.map { layer in
            "\(layer.category.map(CategoryStyle.name) ?? "Free") \(ByteFormatting.string(layer.bytes))"
        }
        return "Storage: " + parts.joined(separator: ", ") + ". Safe to free: \(ByteFormatting.string(safeToFree))."
    }
}

/// The strata's earth tones: daylight for light mode, night for dark mode.
enum Strata {
    static func sky(_ scheme: ColorScheme) -> (Color, Color) {
        scheme == .dark ? (Color(hex: 0x2B241D), Color(hex: 0x3A3027)) : (Color(hex: 0xDCEAF4), Color(hex: 0xF4ECDF))
    }

    static func color(_ category: StorageCategory, _ scheme: ColorScheme) -> Color {
        Color(hex: hex(category, scheme))
    }

    /// Roughly how light a color looks, from 0 to 1.
    static func luminance(_ hex: UInt32) -> Double {
        (0.2126 * Double((hex >> 16) & 0xFF) + 0.7152 * Double((hex >> 8) & 0xFF) + 0.0722 * Double(hex & 0xFF)) / 255
    }

    static func hex(_ category: StorageCategory, _ scheme: ColorScheme) -> UInt32 {
        let night: UInt32 = switch category {
        case .apps: 0x8C7A64
        case .documents: 0xB0603A
        case .photosVideos: 0xC98B2F
        case .iosBackups: 0x9C5B44
        case .developer: 0x5E7A3A
        case .systemData: 0x4C5A6B
        case .macOS: 0x3A3F4A
        case .other: 0x6E5C49
        }
        let day: UInt32 = switch category {
        case .apps: 0xC9B596
        case .documents: 0xD4865A
        case .photosVideos: 0xE3AD48
        case .iosBackups: 0xC07F63
        case .developer: 0x89A35A
        case .systemData: 0x7F8EA0
        case .macOS: 0x5C6371
        case .other: 0xA38C70
        }
        return scheme == .dark ? night : day
    }
}
