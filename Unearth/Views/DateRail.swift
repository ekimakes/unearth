import SwiftUI
import UnearthCore

/// The years down the right edge of a timeline, each where it starts. Clicking jumps to the month at that point;
/// dragging scrubs through the whole timeline, naming the month under the pointer.
struct DateRail: View {
    let timeline: Timeline
    let layout: SectionLayout
    let tracker: TimelineScroll
    let onScroll: (Double) -> Void
    @State private var pointer: CGFloat?
    @State private var dragging = false
    @State private var hovering = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let scrollable = max(1, layout.height - tracker.viewport)
            ZStack(alignment: .topTrailing) {
                Capsule().fill(Color.hairline).frame(width: 2).padding(.trailing, 11)
                ForEach(marks(height: height, scrollable: scrollable), id: \.label) { mark in
                    Text(name(mark.label))
                        .font(.size(10.5, weight: mark.isYear ? .bold : .medium))
                        .foregroundStyle(mark.isYear ? Color.ink : Color.secondaryInk)
                        .fixedSize()
                        .padding(.trailing, 17)
                        .offset(y: mark.y)
                }
                RailThumb(tracker: tracker, scrollable: scrollable, height: height)
                if let pointer {
                    Text(month(at: pointer, height: height, scrollable: scrollable))
                        .font(.size(12, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.surface, in: Capsule())
                        .overlay { Capsule().strokeBorder(Color.hairline) }
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        .fixedSize()
                        .offset(x: -30, y: min(max(0, pointer - 12), height - 24))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: height, alignment: .topTrailing)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragging = true
                    pointer = value.location.y
                    onScroll(offset(at: value.location.y, height: height, scrollable: scrollable))
                }
                .onEnded { value in
                    dragging = false
                    if !hovering { pointer = nil }
                    // A click, rather than a drag, lands on the start of the month there.
                    if abs(value.translation.height) < 3,
                       let section = layout.section(at: offset(at: value.location.y, height: height, scrollable: scrollable)) {
                        onScroll(layout.starts[section])
                    }
                })
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hovering = true
                    pointer = location.y
                case .ended:
                    hovering = false
                    if !dragging { pointer = nil }
                }
            }
        }
        .frame(width: TimelineMetrics.railWidth)
        .padding(.vertical, 12)
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        // Read only for VoiceOver: otherwise every point of scrolling would redraw the whole rail.
        .accessibilityValue(voiceOver ? month(atOffset: tracker.offset) : "")
        .accessibilityAdjustableAction { direction in
            guard let section = layout.section(at: tracker.offset) else { return }
            let next = direction == .increment ? min(section + 1, layout.starts.count - 1) : max(section - 1, 0)
            onScroll(layout.starts[next])
        }
    }

    private func offset(at y: CGFloat, height: CGFloat, scrollable: Double) -> Double {
        min(max(0, Double(y / max(1, height))), 1) * scrollable
    }

    private func month(at y: CGFloat, height: CGFloat, scrollable: Double) -> String {
        month(atOffset: offset(at: y, height: height, scrollable: scrollable))
    }

    private func month(atOffset offset: Double) -> String {
        guard let section = layout.section(at: offset), timeline.sections.indices.contains(section) else { return "" }
        return timeline.sections[section].key.title(calendar: timeline.calendar)
    }

    /// The years, and the months and days that fit between them, each where it starts.
    private func marks(height: CGFloat, scrollable: Double) -> [RailMark] {
        let span = Double(height - 12)
        return FileSection.railMarks(timeline.sections, positions: layout.starts.map { min($0 / scrollable, 1) * span }, spacing: 16)
    }

    private func name(_ label: RailMark.Label) -> String {
        let calendar = timeline.calendar
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .now
        }
        return switch label {
        case .year(let year): String(year)
        case .month(let year, let month): date(year, month, 15).formatted(style.month(.abbreviated))
        case .day(let year, let month, let day): date(year, month, day).formatted(style.day().month(.abbreviated))
        }
    }
}

extension RailMark {
    var isYear: Bool { if case .year = label { true } else { false } }
}

/// Where the view is along the rail. On its own, so scrolling redraws only this and not the names.
struct RailThumb: View {
    let tracker: TimelineScroll
    let scrollable: Double
    let height: CGFloat

    var body: some View {
        Capsule()
            .fill(Color.unearth)
            .frame(width: 4, height: 22)
            .padding(.trailing, 10)
            .offset(y: min(max(0, tracker.offset / scrollable), 1) * (height - 22))
    }
}
