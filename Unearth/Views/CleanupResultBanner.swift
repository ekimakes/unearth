import SwiftUI
import UnearthCore

/// Shown while files move to the Trash, so a big selection never looks like nothing is happening.
struct TrashProgressBanner: View {
    let progress: TrashProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).progressViewStyle(.linear).tint(.unearth)
        }
        .padding(16)
        .galleryCard()
    }

    private var title: String {
        let count = "\(progress.done.formatted()) of \(progress.total.formatted())"
        if progress.deleting { return progress.total == 1 ? "Deleting permanently…" : "Deleting \(count) permanently…" }
        return progress.total == 1 ? "Moving to the Trash…" : "Moving \(count) to the Trash…"
    }
}

/// Shown once things have left the Trash for good: what went, and the space that's back.
struct DeletedBanner: View {
    let result: DeletionResult
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Color.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.headline).font(.headline)
                Text(result.detail).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button { model.lastDeleted = nil } label: { Image(systemName: "xmark").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .padding(16)
        .galleryCard()
    }
}

/// Shown after a cleanup: what moved, how to get the space back, Undo, and anything that was skipped.
struct CleanupResultBanner: View {
    let outcome: CleanupOutcome
    @Environment(AppModel.self) private var model
    @State private var confirmingDelete = false
    @State private var showingSkipped = false

    private var inTrash: [HistoryEntry] { outcome.entries.filter { $0.state == .inTrash } }
    private var toolRun: HistoryEntry? { outcome.entries.first { $0.kind == .toolRun } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: outcome.entries.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(outcome.entries.isEmpty ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline).font(.headline)
                if let detail { Text(detail).foregroundStyle(.secondary) }
                if outcome.entries.isEmpty, outcome.failures.count == 1 {
                    // With nothing else to report, the reason is the message.
                    Text(outcome.failures[0].reason).foregroundStyle(.secondary)
                } else if !outcome.failures.isEmpty {
                    Button(outcome.failures.count == 1 ? "1 item was skipped" : "\(outcome.failures.count) items were skipped") {
                        showingSkipped.toggle()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    if showingSkipped {
                        ForEach(Array(outcome.failures.enumerated()), id: \.offset) { _, failure in
                            Text("\(failure.title): \(failure.reason)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 12)
            if !inTrash.isEmpty {
                Button("Undo") { Task { await model.undoLastCleanup() } }
                Button("Delete permanently…") { confirmingDelete = true }
            }
            Button {
                model.lastOutcome = nil
                model.lastFailures = []
            } label: {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(16)
        .galleryCard()
        .alert(inTrash.count == 1 ? "Permanently delete the item Unearth just moved?" :
                "Permanently delete the \(inTrash.count) items Unearth just moved?", isPresented: $confirmingDelete) {
            Button("Delete permanently", role: .destructive) { Task { await model.deletePermanently(inTrash.map(\.id)) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. Everything else in the Trash stays where it is.")
        }
    }

    private var headline: String {
        if let toolRun {
            return toolRun.state == .completed ? "\(toolRun.title) finished." : "\(toolRun.title) didn't finish."
        }
        if outcome.entries.isEmpty { return "Nothing was moved." }
        let size = ByteFormatting.string(outcome.bytesMovedToTrash)
        if model.options.dryRun { return "Dry run: \(size) would have moved to the Trash." }
        return model.lastRemoved ?? "Moved \(size) to the Trash."
    }

    private var detail: String? {
        if toolRun != nil { return toolRun?.state == .completed ? "This was permanent, so it isn't in the Trash." : nil }
        if inTrash.isEmpty { return model.options.dryRun ? "Nothing was touched." : nil }
        return CleanupMessage.detail(bytes: outcome.bytesMovedToTrash)
    }
}

/// Problems from Undo or permanent deletion, after the result banner is gone.
struct FailureBanner: View {
    let failures: [CleanupFailure]
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline).font(.headline)
                ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                    Text(failure.title.isEmpty ? failure.reason : "\(failure.title): \(failure.reason)")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { model.lastFailures = [] } label: { Image(systemName: "xmark").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .padding(16)
        .galleryCard()
    }

    private var headline: String {
        if failures.allSatisfy({ $0.reason == AppModel.goneReason }) {
            return failures.count == 1 ? "1 file is no longer there" : "\(failures.count) files are no longer there"
        }
        if failures.allSatisfy({ $0.reason == AppModel.offlineReason }) {
            return failures.count == 1 ? "1 file is on a disconnected drive" : "\(failures.count) files are on a disconnected drive"
        }
        return failures.count == 1 ? "1 item couldn't be changed" : "\(failures.count) items couldn't be changed"
    }
}
