import SwiftUI
import UnearthCore

/// The last look before anything moves: the chosen items, a total, and one clear button.
struct ReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<CleanupItem.ID>
    @State private var working = false
    private let offered: Set<CleanupItem.ID>

    init(itemIDs: Set<CleanupItem.ID>) {
        offered = itemIDs
        _chosen = State(initialValue: itemIDs)
    }

    private var items: [CleanupItem] {
        (model.plan?.items ?? []).filter { offered.contains($0.id) && $0.action == .trash }.sorted { $0.bytes > $1.bytes }
    }

    private var total: Int64 {
        model.plan?.totalBytes(of: chosen) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Move these to the Trash?").font(.title2.weight(.bold))
                Text("You can put them back until you empty the Trash. The space comes back once the Trash is emptied.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            CheckBox(isOn: chosen.contains(item.id)) {
                                if chosen.contains(item.id) { chosen.remove(item.id) } else { chosen.insert(item.id) }
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).lineLimit(1).truncationMode(.middle)
                                Text(item.group).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            SafetyBadge(safety: item.safety)
                            SizeLabel(bytes: item.bytes).frame(minWidth: 70, alignment: .trailing)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                    }
                }
            }
            .frame(maxHeight: 340)
            .galleryCard(radius: 10)

            HStack {
                Text("\(chosen.count) of \(items.count) chosen").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move \(ByteFormatting.string(total)) to the Trash") {
                    working = true
                    Task {
                        await model.moveToTrash(chosen)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || working)
            }
        }
        .padding(24)
        .frame(width: 600)
        .tint(.unearth)
    }
}
