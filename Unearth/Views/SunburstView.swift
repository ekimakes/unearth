import SwiftUI
import UnearthCore

struct SunburstSegment: Identifiable, Equatable {
    let id: Int
    /// Nil for the grouped "smaller items" and "files in this folder" slices.
    let node: NodeID?
    let name: String
    let bytes: Int64
    /// 1 is the ring closest to the center.
    let depth: Int
    let start: Double
    let end: Double
    /// Index into the palette; -1 for neutral slices.
    let hue: Int
    var isRest = false
}

/// Rings of folders around the one in focus: up to three levels deep, clockwise from the top.
struct SunburstView: View {
    let segments: [SunburstSegment]
    let focusName: String
    let focusBytes: Int64
    @Binding var hovered: SunburstSegment?
    let onSelect: (SunburstSegment) -> Void

    static let palette: [Color] = CategoryStyle.order.map(CategoryStyle.color)
    private static let rings = 3

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let outer = min(geometry.size.width, geometry.size.height) / 2 - 2
            let inner = outer * 0.32
            let ring = (outer - inner) / Double(Self.rings)
            ZStack {
                Canvas { context, _ in
                    for segment in segments {
                        let path = Self.path(segment, center: center, inner: inner, ring: ring)
                        context.fill(path, with: .color(color(segment)))
                    }
                }
                VStack(spacing: 2) {
                    Text(hovered?.name ?? focusName)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    SizeLabel(bytes: hovered?.bytes ?? focusBytes, size: 20, weight: .bold)
                }
                .frame(width: inner * 1.6)
                .position(center)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hovered = hit(location, center: center, inner: inner, ring: ring)
                case .ended: hovered = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                if let segment = hit(location, center: center, inner: inner, ring: ring) { onSelect(segment) }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Disk map of \(focusName), \(ByteFormatting.string(focusBytes))")
    }

    private func color(_ segment: SunburstSegment) -> Color {
        let base = segment.hue >= 0 ? Self.palette[segment.hue % Self.palette.count] : Color.secondary
        let strength = segment.isRest ? 0.28 : [0.95, 0.72, 0.52][min(2, segment.depth - 1)]
        let highlight = hovered?.id == segment.id ? 0.18 : 0
        return base.opacity(min(1, strength * (segment.hue >= 0 ? 1 : 0.45) + highlight))
    }

    private static func path(_ segment: SunburstSegment, center: CGPoint, inner: Double, ring: Double) -> Path {
        let gap = 0.004
        let start = segment.start + gap
        let end = max(start + 0.001, segment.end - gap)
        let r0 = inner + ring * Double(segment.depth - 1) + 1
        let r1 = r0 + ring - 2
        var path = Path()
        path.addArc(center: center, radius: r1, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        path.addArc(center: center, radius: r0, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
        path.closeSubpath()
        return path
    }

    private func hit(_ point: CGPoint, center: CGPoint, inner: Double, ring: Double) -> SunburstSegment? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius = (dx * dx + dy * dy).squareRoot()
        guard radius > inner else { return nil }
        let depth = Int((radius - inner) / ring) + 1
        guard depth <= Self.rings else { return nil }
        var angle = atan2(dy, dx)
        if angle < -.pi / 2 { angle += 2 * .pi }
        return segments.first { $0.depth == depth && angle >= $0.start && angle < $0.end }
    }

    /// Slices for `focus`: children sized by bytes; anything under one degree joins "Smaller items".
    static func segments(tree: ScanTree, focus: NodeID) -> [SunburstSegment] {
        var result: [SunburstSegment] = []
        func walk(_ id: NodeID, depth: Int, start: Double, span: Double, hue: Int?) {
            let node = tree.node(id)
            let total = Double(max(1, node.totalBytes))
            var angle = start
            var rest = node.ownBytes
            for (index, child) in node.children.enumerated() {
                let childNode = tree.node(child)
                let childSpan = span * Double(childNode.totalBytes) / total
                guard childSpan >= .pi / 180 else {
                    rest += childNode.totalBytes
                    continue
                }
                let childHue = hue ?? index
                result.append(SunburstSegment(id: result.count, node: child, name: childNode.name, bytes: childNode.totalBytes,
                                              depth: depth, start: angle, end: angle + childSpan, hue: childHue))
                if depth < rings { walk(child, depth: depth + 1, start: angle, span: childSpan, hue: childHue) }
                angle += childSpan
            }
            let restSpan = span * Double(rest) / total
            if restSpan > 0.002 {
                // Loose files take their folder's color, faintly; grouped small folders stay neutral.
                let onlyFiles = rest == node.ownBytes
                result.append(SunburstSegment(id: result.count, node: nil,
                                              name: onlyFiles ? "Files in this folder" : "Smaller items",
                                              bytes: rest, depth: depth, start: angle, end: angle + restSpan,
                                              hue: onlyFiles ? (hue ?? -1) : -1, isRest: true))
            }
        }
        walk(focus, depth: 1, start: -.pi / 2, span: 2 * .pi, hue: nil)
        return result
    }
}
