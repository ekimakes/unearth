import SwiftUI
import UnearthCore

/// Results for what's typed in the search field, in place of the current screen.
struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    @State private var hits: [SearchHit] = []
    @State private var searchedQuery = SearchQuery()
    @State private var removed: Set<QueryChip> = []
    @State private var selection: Set<Int64> = []
    @State private var trashing: [IndexedFile] = []
    @AppStorage("browseLayout") private var layout: FileLayout = .grid

    private struct SearchKey: Equatable {
        let text: String
        let removed: Set<QueryChip>
        let revision: Int
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                SearchResultsContent(query: searchedQuery, hits: hits, selection: $selection, trashing: $trashing, layout: layout,
                                     onRemove: { removed.insert($0) }, onCursor: { proxy.scrollTo($0) })
            }
        }
        .background(Color.canvas)
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                SelectionBar(files: hits.map(\.file).filter { selection.contains($0.id) }, trashing: $trashing, selection: $selection)
            }
        }
        .trashConfirmation($trashing)
        .onChange(of: model.searchText) { removed = [] }
        .task(id: SearchKey(text: model.searchText, removed: removed, revision: model.library.revision)) {
            // Wait for a pause in typing.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let query = removed.reduce(SearchQuery.parse(model.searchText, now: Date())) { $0.removing($1) }
            let found = await model.library.search(query)
            guard !Task.isCancelled else { return }
            hits = found
            searchedQuery = query
            selection.formIntersection(found.map(\.id))
        }
    }
}

/// The chips, the count and the results, without the scroll view.
struct SearchResultsContent: View {
    @Environment(AppModel.self) private var model
    let query: SearchQuery
    let hits: [SearchHit]
    @Binding var selection: Set<Int64>
    @Binding var trashing: [IndexedFile]
    var layout: FileLayout = .grid
    var onRemove: (QueryChip) -> Void = { _ in }
    var onCursor: (Int64) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !query.chips.isEmpty { chips }
            VStack(alignment: .leading, spacing: 4) {
                Text(summary).font(.title2.weight(.semibold))
                if let foundBy { Text(foundBy).foregroundStyle(.secondary) }
            }
            if hits.isEmpty {
                ContentUnavailableView {
                    Label("No files match", systemImage: "magnifyingglass")
                } description: {
                    Text(emptyHint)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                let badges = Dictionary(uniqueKeysWithValues: hits.map { ($0.id, $0.reason.badge) })
                FileGrid(files: hits.map(\.file), layout: layout, selection: $selection, trashing: $trashing,
                         note: { badges[$0.id] ?? nil }, onCursor: onCursor)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(query.chips, id: \.self) { chip in
                Button { onRemove(chip) } label: {
                    HStack(spacing: 5) {
                        Text(chip.label)
                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .foregroundStyle(.tint)
                    .background(Color.unearth.opacity(0.14), in: Capsule())
                    .overlay { Capsule().strokeBorder(Color.unearth.opacity(0.5)) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove filter: \(chip.label)")
            }
        }
    }

    private var summary: String {
        let count = hits.count == 1 ? "1 match" : "\(hits.count.formatted()) matches"
        return query.text.isEmpty ? count : "\(count) for “\(query.text)”"
    }

    /// "Found by name and by text inside images."; "Newest first." when only filters chose the files.
    private var foundBy: String? {
        if hits.count >= LibraryModel.searchLimit { return "Showing the newest \(LibraryModel.searchLimit.formatted()). Add a word or a filter to narrow it down." }
        if query.text.isEmpty, !hits.isEmpty { return "Newest first." }
        var ways: [String] = []
        func add(_ way: String, if found: Bool) { if found, !ways.contains(way) { ways.append(way) } }
        for hit in hits {
            switch hit.reason {
            case .name: add("by name", if: true)
            case .text: add("by text inside images", if: true)
            case .label: add("by what's in images", if: true)
            case .folder: add("by folder", if: true)
            case .filters: break
            }
        }
        guard !ways.isEmpty else { return nil }
        return "Found " + ways.formatted(.list(type: .and)) + "."
    }

    private var emptyHint: String {
        if case .recognizing(let done, let total) = model.library.status, total > done {
            let left = total - done
            return "Text inside images is still being read: \(left.formatted()) \(left == 1 ? "image" : "images") to go."
        }
        if model.library.isIndexing { return "Unearth is still building your Library." }
        return query.chips.isEmpty ? "Try other words, or fewer of them." : "Try other words, or remove a filter."
    }
}
