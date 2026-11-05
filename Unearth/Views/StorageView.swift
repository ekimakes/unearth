import SwiftUI
import UnearthCore

/// Storage: the disk as strata, then System Data and the largest files.
struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var reviewing = false

    var body: some View {
        ScrollView {
            StorageContent(onReview: { reviewing = true })
        }
        .background(Color.canvas)
        .sheet(isPresented: $reviewing) {
            ReviewSheet(itemIDs: model.plan?.defaultSelection() ?? [])
        }
    }
}

/// The Storage screen without its scroll view, so it can also be rendered to an image.
struct StorageContent: View {
    @Environment(AppModel.self) private var model
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            if let breakdown = model.breakdown {
                StrataView(breakdown: breakdown, safeToFree: model.safeToFree, onReview: onReview, onOpen: open)
            } else if case .scanning(let progress) = model.phase {
                ScanProgressCard(progress: progress)
            }
            if case .failed(let message) = model.phase {
                failure(message)
            }
            if model.breakdown != nil {
                HStack(alignment: .top, spacing: 14) {
                    systemData
                    largestFiles
                }
            }
        }
        .padding(EdgeInsets(top: 22, leading: 28, bottom: 32, trailing: 28))
        .frame(maxWidth: 1_160, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.volumes?.volume(withRole: "System")?.name ?? "Your Mac")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color.ink)
            if let volumes = model.volumes {
                Text("\(ByteFormatting.string(volumes.used)) of \(ByteFormatting.string(volumes.container.capacity)) used, layer by layer")
                    .monospacedDigit()
                    .foregroundStyle(Color.secondaryInk)
            }
        }
    }

    /// System Data and Developer have screens of their own; the rest opens the Disk Map on the category's
    /// biggest folder.
    private func open(_ category: StorageCategory) {
        switch category {
        case .systemData:
            model.sidebarSelection = .systemData
        case .developer:
            model.sidebarSelection = .developer
        default:
            guard let tree = model.tree, let folder = model.breakdown?.categoryContributors[category]?.first else { return }
            model.diskMapFocus = tree.path(of: folder.node)
            model.sidebarSelection = .diskMap
        }
    }

    private var systemData: some View {
        Tile(title: "System Data, explained", action: ("Show all", { model.sidebarSelection = .systemData })) {
            if let breakdown = model.breakdown {
                ForEach(breakdown.systemData.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(3), id: \.key) { bucket, bytes in
                    TileRow(name: CategoryStyle.name(bucket), bytes: bytes)
                }
            }
        }
    }

    private var largestFiles: some View {
        Tile(title: "Largest files", action: ("Show all", { model.sidebarSelection = .largeFiles })) {
            if let files = model.tree?.bigFiles.prefix(3), !files.isEmpty {
                ForEach(Array(files), id: \.path) { file in
                    TileRow(name: (file.path as NSString).lastPathComponent, bytes: file.bytes)
                }
            } else {
                Text("No files over 50 MB.").foregroundStyle(Color.secondaryInk)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The scan stopped", systemImage: "exclamationmark.triangle").font(.headline)
            Text(message).foregroundStyle(Color.secondaryInk)
            Button("Scan again") { Task { await model.startScan() } }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .galleryCard()
    }
}

struct ScanProgressCard: View {
    let progress: ScanProgress

    var body: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text("Measuring your disk: \(progress.files.formatted()) files so far")
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                Text(progress.currentPath)
                    .font(.callout)
                    .foregroundStyle(Color.secondaryInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .galleryCard()
    }
}

/// A Gallery card with a title, a link to the full screen, and a few rows.
struct Tile<Content: View>: View {
    let title: String
    let action: (String, () -> Void)
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, action: (action.0, action.1))
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .galleryCard()
    }
}

struct TileRow: View {
    let name: String
    let bytes: Int64

    var body: some View {
        HStack {
            Text(name).lineLimit(1).truncationMode(.middle).foregroundStyle(Color.ink)
            Spacer(minLength: 8)
            SizeLabel(bytes: bytes).foregroundStyle(Color.secondaryInk)
        }
    }
}
