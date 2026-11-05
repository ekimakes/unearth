import SwiftUI
import UnearthCore

extension FileSection.Key {
    /// "October 2026", a folder's name, or a download source.
    func title(calendar: Calendar) -> String {
        switch self {
        case .month(let year, let month):
            let date = calendar.date(from: DateComponents(year: year, month: month, day: 15)) ?? .now
            return date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.wide).year())
        case .day(let year, let month, let day):
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .now
            return date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).day().month(.wide).year())
        case .folder(let path):
            return path == "/" ? "/" : (path as NSString).lastPathComponent
        case .source(let source):
            return source ?? "No download source"
        case .subfolders:
            return "Folders"
        }
    }

    /// Where a folder is, under its name.
    var place: String? {
        guard case .folder(let path) = self else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == path ? nil : "in " + (parent as NSString).abbreviatingWithTildeInPath
    }
}

extension FileKind {
    /// "1 image", "412 images"; files of many kinds are "files".
    static func count(_ count: Int, of kind: FileKind?) -> String {
        let (one, many) = switch kind {
        case .image: ("image", "images")
        case .screenshot: ("screenshot", "screenshots")
        case .video: ("video", "videos")
        case .document: ("document", "documents")
        case .app: ("app", "apps")
        case .archive: ("archive", "archives")
        default: ("file", "files")
        }
        return count == 1 ? "1 \(one)" : "\(count.formatted()) \(many)"
    }
}

/// A section's name, how many files it has and their size, and a button that selects all of them.
struct TimelineHeader: View {
    let timeline: Timeline
    let section: Int
    let kind: FileKind?
    let selection: Set<Int64>
    let onSelect: () -> Void

    var body: some View {
        if timeline.sections.indices.contains(section) {
            header(timeline.sections[section])
        }
    }

    private func header(_ fileSection: FileSection) -> some View {
        let ids = timeline.ids(in: section)
        let whole = ids.map { !$0.isEmpty && $0.isSubset(of: selection) } ?? false
        return HStack(spacing: 10) {
            HStack(spacing: 10) {
                if case .source(let source?) = fileSection.key { Monogram(name: source, side: 20) }
                Text(fileSection.key.title(calendar: timeline.calendar))
                    .font(.size(19, weight: .bold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityAddTraits(.isHeader)
                if let place = fileSection.key.place {
                    Text(place)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(detail(fileSection))
                    .font(.size(12, weight: .medium))
                    .foregroundStyle(Color.secondaryInk)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .allowsHitTesting(false)
            Spacer(minLength: 12)
            Button(action: onSelect) {
                Label(whole ? "Deselect" : "Select", systemImage: whole ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.system(size: 12, weight: .medium))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(whole ? AnyShapeStyle(Color.unearth) : AnyShapeStyle(Color.secondaryInk))
            .help(whole ? "Deselect everything in \(fileSection.key.title(calendar: timeline.calendar))"
                        : "Select everything in \(fileSection.key.title(calendar: timeline.calendar))")
        }
        .padding(.top, 14)
        .frame(height: TimelineMetrics.headerHeight, alignment: .center)
        // Whether to offer Select or Deselect, for any header on screen, however it got there.
        .task(id: ids == nil ? fileSection.key : nil) { timeline.needIDs(in: section) }
    }

    /// "412 images · 3.1 GB". A folder's size is known only after a disk scan.
    private func detail(_ section: FileSection) -> String {
        let count = section.key == .subfolders ? (section.count == 1 ? "1 folder" : "\(section.count.formatted()) folders")
                                               : FileKind.count(section.count, of: kind)
        return section.bytes > 0 ? "\(count) · \(ByteFormatting.string(section.bytes))" : count
    }
}

/// The header of the section at the top of the view, kept there and pushed up as the next one arrives. Only its
/// button takes clicks, so the wheel still scrolls the timeline under it.
struct PinnedTimelineHeader: View {
    let timeline: Timeline
    let tracker: TimelineScroll
    let kind: FileKind?
    let selection: Set<Int64>
    let onSelectSection: (Int) -> Void

    var body: some View {
        if let pinned = tracker.pinned, tracker.offset > 0.5, timeline.sections.indices.contains(pinned.section) {
            TimelineHeader(timeline: timeline, section: pinned.section, kind: kind, selection: selection) {
                onSelectSection(pinned.section)
            }
            .background {
                Color.canvas
                    .padding(.horizontal, -TimelineMetrics.padding)
                    .overlay(alignment: .bottom) { Color.hairline.frame(height: 1).padding(.horizontal, -TimelineMetrics.padding) }
                    .allowsHitTesting(false)
            }
            .offset(y: pinned.offset)
        }
    }
}
