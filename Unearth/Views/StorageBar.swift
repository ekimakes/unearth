import SwiftUI
import UnearthCore

/// The disk as one bar: a segment per category, then free space in stripes.
struct StorageBar: View {
    struct Segment: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
        let color: Color
        var isFree = false
    }

    let segments: [Segment]
    var height: CGFloat = 26

    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let visible = segments.filter { $0.bytes > 0 }
            let total = CGFloat(max(1, visible.reduce(0) { $0 + $1.bytes }))
            let available = geometry.size.width - gap * CGFloat(max(0, visible.count - 1))
            HStack(spacing: gap) {
                ForEach(visible) { segment in
                    fill(for: segment)
                        .frame(width: max(2, available * CGFloat(segment.bytes) / total))
                        .help("\(segment.name): \(ByteFormatting.string(segment.bytes))")
                        .accessibilityElement()
                        .accessibilityLabel("\(segment.name), \(ByteFormatting.string(segment.bytes))")
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
    }

    @ViewBuilder
    private func fill(for segment: Segment) -> some View {
        if segment.isFree {
            Rectangle().fill(Color.freeSpace)
        } else {
            Rectangle().fill(segment.color)
        }
    }

    static func segments(for breakdown: StorageBreakdown) -> [Segment] {
        CategoryStyle.order.map { category in
            Segment(id: category.rawValue, name: CategoryStyle.name(category), bytes: breakdown.segments[category] ?? 0,
                    color: CategoryStyle.color(category))
        } + [Segment(id: "free", name: "Free", bytes: breakdown.free, color: .clear, isFree: true)]
    }

    /// Before the scan finishes, only macOS and free space are known.
    static func segments(for volumes: VolumeInventory) -> [Segment] {
        let system = volumes.volume(withRole: "System")?.capacityInUse ?? 0
        return [
            Segment(id: "macOS", name: "macOS", bytes: system, color: CategoryStyle.color(.macOS)),
            Segment(id: "scanning", name: "Being measured", bytes: max(0, volumes.used - system), color: .secondary.opacity(0.35)),
            Segment(id: "free", name: "Free", bytes: volumes.container.free, color: .clear, isFree: true),
        ]
    }
}
