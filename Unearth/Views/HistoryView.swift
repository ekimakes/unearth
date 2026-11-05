import SwiftUI
import UnearthCore

/// Everything Unearth moved or ran, newest first, with Undo while items are still in the Trash.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete: HistoryEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Cleanup history").font(.title2.weight(.bold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            if model.history.isEmpty {
                ContentUnavailableView("Nothing cleaned yet", systemImage: "clock",
                                       description: Text("Everything Unearth moves to the Trash shows up here, so you can put it back."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.history.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider() }
                            row(entry)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            if !model.lastFailures.isEmpty {
                FailureBanner(failures: model.lastFailures).padding(16)
            }
        }
        .frame(width: 680, height: 500)
        .tint(.unearth)
        .task { await model.refreshHistory() }
        .alert("Permanently delete \(confirmingDelete?.title ?? "this item")?", isPresented: Binding(
            get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } })) {
            Button("Delete permanently", role: .destructive) {
                if let entry = confirmingDelete { Task { await model.deletePermanently([entry.id]) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1).truncationMode(.middle)
                Text(entry.originalPath ?? entry.commandLine ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(Self.stateLabel(entry)).font(.callout).foregroundStyle(.secondary)
            SizeLabel(bytes: entry.bytes).frame(minWidth: 70, alignment: .trailing)
            if entry.state == .inTrash {
                Button("Undo") { Task { await model.undo([entry.id]) } }
                Button("Delete…") { confirmingDelete = entry }
            }
        }
        .padding(.vertical, 10)
    }

    static func stateLabel(_ entry: HistoryEntry) -> String {
        switch (entry.kind, entry.state) {
        case (_, .inTrash): "In the Trash"
        case (_, .restored): "Put back"
        case (_, .deletedPermanently): "Deleted"
        case (_, .goneFromTrash): "Trash emptied"
        case (.toolRun, .completed): "Done, permanent"
        case (.trashed, .completed): "Dry run"
        case (_, .failed): "Didn't finish"
        }
    }
}
