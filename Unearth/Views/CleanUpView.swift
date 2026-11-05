import AppKit
import SwiftUI
import UnearthCore

/// Clean up › Overview: every collection as a pile, the safe-to-free plan first.
struct CleanUpView: View {
    @Environment(AppModel.self) private var model
    @State private var reviewing = false

    var body: some View {
        ScrollView {
            CleanUpContent(onReview: { reviewing = true })
        }
        .background(Color.canvas)
        .sheet(isPresented: $reviewing) {
            ReviewSheet(itemIDs: model.plan?.defaultSelection() ?? [])
        }
    }
}

/// The overview without its scroll view, so it can also be rendered to an image.
struct CleanUpContent: View {
    @Environment(AppModel.self) private var model
    let onReview: () -> Void

    var body: some View {
        let collections = model.collections
        let kinds = CollectionKind.shown(in: collections)
        VStack(alignment: .leading, spacing: 18) {
            Text("Everything here goes to the Trash, where you can put it back until you empty it.")
                .font(.title3)
                .foregroundStyle(Color.secondaryInk)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                if model.safeToFree > 0 {
                    Button(action: onReview) {
                        PileView(items: model.leftoverPileItems, title: "Caches & leftovers", bytes: model.safeToFree,
                                 detail: "Safe to remove, rebuilds itself", highlighted: true, large: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Review what's safe to remove")
                }
                ForEach(kinds, id: \.self) { kind in
                    let summary = collections.summaries[kind]
                    Button { model.sidebarSelection = .collection(kind) } label: {
                        PileView(items: collections.pileItems(kind), title: kind.title, bytes: summary?.bytes ?? 0,
                                 detail: kind.detail(count: summary?.count ?? 0, settings: collections.settings), large: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens \(kind.title)")
                }
            }
            if kinds.isEmpty, model.safeToFree == 0, !collections.isWorking {
                ContentUnavailableView("Nothing to clean up right now", systemImage: "sparkles",
                                       description: Text("Unearth looks again after every scan and whenever your files change."))
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
            if collections.isWorking {
                Label("Still looking for duplicates and look-alike photos", systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(Color.secondaryInk)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension CollectionKind {
    /// The collections with something in them, the most space first.
    @MainActor static func shown(in collections: CollectionsModel) -> [CollectionKind] {
        allCases.filter { (collections.summaries[$0]?.count ?? 0) > 0 }
            .sorted { (collections.summaries[$0]?.bytes ?? 0) > (collections.summaries[$1]?.bytes ?? 0) }
    }
}

extension CollectionsModel {
    /// What a collection's pile shows: its files, or for unused apps their icons.
    func pileItems(_ kind: CollectionKind) -> [PileThumbnail] {
        switch kind {
        case .unusedApps: apps.prefix(3).map { .icon(ThumbnailCache.shared.folderIcon($0.path)) }
        default: (summaries[kind]?.preview ?? []).map(PileThumbnail.file)
        }
    }
}

extension AppModel {
    /// The Caches & leftovers pile: the apps behind the biggest safe items, or plain symbols.
    var leftoverPileItems: [PileThumbnail] {
        let safe = (plan?.items ?? []).filter(\.isSelectableByDefault).sorted { $0.bytes > $1.bytes }
        var icons: [PileThumbnail] = []
        var seen: Set<String> = []
        for item in safe {
            guard icons.count < 3, let owner = item.owner, seen.insert(owner).inserted,
                  let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: owner) else { continue }
            icons.append(.icon(ThumbnailCache.shared.folderIcon(app.path)))
        }
        let symbols: [PileThumbnail] = [.symbol("shippingbox", .unearth), .symbol("hammer", .secondaryInk),
                                        .symbol("doc.zipper", .secondaryInk)]
        return icons + symbols.prefix(3 - icons.count)
    }
}
