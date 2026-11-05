import QuickLook
import SwiftUI
import UnearthCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showingHistory = false
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool {
        !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            let item = model.sidebarSelection ?? .home
            Group {
                if isSearching {
                    SearchResultsView()
                } else {
                    detail(for: item)
                }
            }
                .safeAreaInset(edge: .top) { banner }
                .navigationTitle(isSearching ? "Search" : item.title)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            Task { await model.startScan() }
                        } label: {
                            Label("Scan again", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isScanning || model.isRefreshing)
                        .help("Scan the disk again")

                        Button {
                            showingHistory = true
                        } label: {
                            Label("Cleanup history", systemImage: "clock.arrow.circlepath")
                        }
                        .help("Everything Unearth moved to the Trash, with Undo")
                    }
                }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search files")
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequests) { searchFocused = true }
        // Picking a screen leaves the search.
        .onChange(of: model.sidebarSelection) { model.searchText = "" }
        .sheet(isPresented: $showingHistory) {
            HistoryView()
        }
        .quickLookPreview(Binding(get: { model.previewURL }, set: { model.previewURL = $0 }))
        .tint(.unearth)
    }

    @ViewBuilder
    private var banner: some View {
        if let progress = model.trashProgress {
            TrashProgressBanner(progress: progress).padding(.horizontal, 24).padding(.top, 12)
        } else if let outcome = model.lastOutcome {
            CleanupResultBanner(outcome: outcome).padding(.horizontal, 24).padding(.top, 12)
        } else if !model.lastFailures.isEmpty {
            FailureBanner(failures: model.lastFailures).padding(.horizontal, 24).padding(.top, 12)
        }
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .home:
            HomeView()
        case .storage:
            StorageView()
        case .recents:
            BrowseView(scope: .recents).id(item)
        case .kind(let kind):
            BrowseView(scope: .kind(kind)).id(item)
        case .source(let source):
            BrowseView(scope: .source(source)).id(item)
        case .downloadedFrom:
            SourcesView()
        case .place(let path):
            PlacesView(root: path).id(item)
        case .junk:
            CleanupSectionView(section: .junk)
        case .developer:
            CleanupSectionView(section: .developer)
        case .diskMap:
            DiskMapView()
        case .systemData:
            SystemDataView()
        case .largeFiles:
            LargeFilesView()
        case .cleanUp:
            CleanUpView()
        case .collection(let kind):
            CollectionReviewView(kind: kind).id(item)
        }
    }
}
