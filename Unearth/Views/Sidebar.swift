import SwiftUI
import UnearthCore

/// One row of the sidebar: the screen it opens, its label and what it shows on the right.
struct SidebarRow: Identifiable {
    enum Icon {
        case symbol(String, Color)
        case monogram(String)
    }

    let item: SidebarItem
    let title: String
    let icon: Icon
    let badge: String?
    /// The safe-to-free figure, in Unearth orange.
    var highlighted = false
    var id: SidebarItem { item }
}

struct SidebarSection: Identifiable {
    let title: String?
    let rows: [SidebarRow]
    var id: String { title ?? "" }
}

struct SidebarRowLabel: View {
    let row: SidebarRow

    var body: some View {
        Label {
            Text(row.title)
        } icon: {
            switch row.icon {
            case .symbol(let name, let color): Image(systemName: name).foregroundStyle(color)
            case .monogram(let name): Monogram(name: name, side: 16)
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    /// Sources listed by name; the rest are one click away in Downloaded from.
    static let sourcesShown = 5

    var body: some View {
        @Bindable var model = model
        // The meter sits below the list rather than over it, so rows never slide under it.
        VStack(spacing: 0) {
            List(selection: $model.sidebarSelection) {
                ForEach(Self.sections(model)) { section in
                    if let title = section.title {
                        Section(title) { rows(section) }
                    } else {
                        rows(section)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            VStack(alignment: .leading, spacing: 10) {
                LibraryStatusLine()
                FreeSpaceMeter()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.sidebarFill)
    }

    private func rows(_ section: SidebarSection) -> some View {
        ForEach(section.rows) { row in
            SidebarRowLabel(row: row)
                .badge(row.badge.map { badge in
                    row.highlighted ? Text(badge).monospacedDigit().foregroundStyle(Color.unearth) : Text(badge).monospacedDigit()
                })
                .tag(row.item)
        }
    }

    /// The sidebar, top to bottom: Home and Recents, the Library by kind, Clean up, where downloads came from,
    /// Storage and Places.
    static func sections(_ model: AppModel) -> [SidebarSection] {
        let library = model.library
        let collections = model.collections
        let planned = model.plan != nil
        func row(_ item: SidebarItem, title: String? = nil, tint: Color = .secondaryInk, bytes: Int64? = nil, count: Int? = nil,
                 highlighted: Bool = false) -> SidebarRow {
            let badge = bytes.flatMap { $0 > 0 ? ByteFormatting.string($0) : nil } ?? count.flatMap { $0 > 0 ? $0.formatted() : nil }
            return SidebarRow(item: item, title: title ?? item.title, icon: .symbol(item.symbol, tint), badge: badge,
                              highlighted: highlighted)
        }
        var sections = [
            SidebarSection(title: nil, rows: [row(.home), row(.recents)]),
            SidebarSection(title: "Library", rows: SidebarItem.libraryKinds.map { kind in
                row(.kind(kind), tint: kind.color, count: library.count(of: kind))
            }),
            SidebarSection(title: "Clean up", rows: [
                row(.cleanUp, title: "Overview", bytes: planned ? model.safeToFree : nil, highlighted: true),
                row(.junk, bytes: planned ? model.total(of: .junk) : nil),
                row(.developer, bytes: planned ? model.total(of: .developer) : nil),
                row(.collection(.duplicates), bytes: collections.summaries[.duplicates]?.bytes),
                row(.collection(.unusedApps), bytes: collections.summaries[.unusedApps]?.bytes),
                row(.largeFiles, bytes: planned ? model.total(of: .largeFiles) : nil),
            ]),
        ]
        if !library.sources.isEmpty {
            var rows = library.sources.prefix(sourcesShown).map { source in
                SidebarRow(item: .source(source.source), title: source.source, icon: .monogram(source.source),
                           badge: source.count.formatted())
            }
            if library.sources.count > sourcesShown {
                rows.append(row(.downloadedFrom, title: "All sources", count: library.sources.count))
            }
            sections.append(SidebarSection(title: "Downloaded from", rows: rows))
        }
        sections.append(SidebarSection(title: "Storage", rows: [
            row(.storage), row(.systemData, bytes: model.breakdown?.segments[.systemData]), row(.diskMap),
        ]))
        sections.append(SidebarSection(title: "Places", rows: model.places.map { row(.place($0)) }))
        return sections
    }
}

/// What the Library is doing in the background, while it's doing something.
struct LibraryStatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.library.status {
        case .indexing(let files):
            line("Building your Library: \(files.formatted()) files", progress: nil)
        case .recognizing(let done, let total):
            line("Reading text in images: \(done.formatted()) of \(total.formatted())", progress: (done, total))
        default:
            if model.collections.isWorking {
                line("Looking for duplicates and forgotten files", progress: nil)
            }
        }
    }

    private func line(_ text: String, progress: (Int, Int)?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(text).font(.caption).foregroundStyle(.secondary)
            if let (done, total) = progress {
                ProgressView(value: Double(done), total: Double(max(1, total))).controlSize(.small)
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// How full the disk is, always visible at the bottom of the sidebar.
struct FreeSpaceMeter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let volumes = model.volumes {
            let capacity = Double(max(1, volumes.container.capacity))
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(volumes.used), total: capacity)
                    .tint(volumes.container.free < volumes.container.capacity / 10 ? .orange : .unearth)
                Text("\(ByteFormatting.string(volumes.container.free)) free of \(ByteFormatting.string(volumes.container.capacity))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
