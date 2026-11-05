import SwiftUI
import UnearthCore

/// One cleanup section (Caches & junk, Developer & AI, Large & old files) with its selection footer.
struct CleanupSectionView: View {
    let section: CleanupSection
    @Environment(AppModel.self) private var model
    @State private var reviewing = false

    var body: some View {
        let selected = model.selectedIDs(in: section)
        VStack(spacing: 0) {
            ScrollView {
                CleanupSectionContent(section: section)
            }
            .background(Color.canvas)
            Divider()
            HStack(spacing: 10) {
                Text(selected.isEmpty ? "Nothing selected" : "\(selected.count) selected")
                    .foregroundStyle(.secondary)
                if !selected.isEmpty {
                    SizeLabel(bytes: model.plan?.totalBytes(of: selected) ?? 0, weight: .semibold)
                }
                Spacer()
                Button("Move to Trash…") { reviewing = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || model.isScanning)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $reviewing) {
            ReviewSheet(itemIDs: selected)
        }
    }
}

/// The section's groups and rows without the scroll view, so it can also be rendered to an image.
struct CleanupSectionContent: View {
    let section: CleanupSection
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.title(section)).font(.largeTitle.weight(.bold))
                Text(Self.summary(section)).font(.title3).foregroundStyle(.secondary)
            }
            if let plan = model.plan {
                let groups = Self.groups(plan.items(in: section))
                if groups.isEmpty {
                    ContentUnavailableView("Nothing to clean here", systemImage: "checkmark.circle",
                                           description: Text("Unearth didn't find anything in this section on your Mac."))
                } else {
                    ForEach(groups, id: \.name) { group in
                        GroupBlock(name: group.name, items: group.items)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for things to clean…").foregroundStyle(.secondary)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: 940, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func groups(_ items: [CleanupItem]) -> [(name: String, items: [CleanupItem])] {
        Dictionary(grouping: items, by: \.group)
            .map { (name: $0.key, items: $0.value.sorted { $0.bytes > $1.bytes }) }
            .sorted { $0.items.reduce(0) { $0 + $1.bytes } > $1.items.reduce(0) { $0 + $1.bytes } }
    }

    static func title(_ section: CleanupSection) -> String {
        switch section {
        case .junk: "Caches & junk"
        case .developer: "Developer & AI"
        case .largeFiles: "Large & old files"
        case .manual: "Picked by you"
        }
    }

    static func summary(_ section: CleanupSection) -> String {
        switch section {
        case .junk: "Temporary files apps leave behind. Most of them rebuild themselves."
        case .developer: "Build files, simulators, package caches and AI models, often the biggest space users on a developer's Mac."
        case .largeFiles: "Big files you haven't opened in a while."
        case .manual: ""
        }
    }
}

struct GroupBlock: View {
    let name: String
    let items: [CleanupItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: GroupStyle.symbol(name)).foregroundStyle(.secondary).frame(width: 20)
                Text(name).font(.headline)
                Spacer()
                SizeLabel(bytes: items.reduce(0) { $0 + $1.bytes }, weight: .semibold).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 43) }
                    CleanupItemRow(item: item)
                }
            }
            .galleryCard(radius: 12)
        }
    }
}
