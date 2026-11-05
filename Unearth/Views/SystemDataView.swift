import AppKit
import SwiftUI
import UnearthCore

struct SystemDataView: View {
    var body: some View {
        ScrollView { SystemDataContent() }
            .background(Color.canvas)
    }
}

/// What "System Data" is made of, biggest first, without the scroll view.
struct SystemDataContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("System Data").font(.largeTitle.weight(.bold))
                if let total = model.breakdown?.segments[.systemData] {
                    SizeLabel(bytes: total, size: 34, weight: .bold)
                }
                Text("The space macOS files under System Data, split into what's really in it. Unearth measures this itself, so it can differ a little from System Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.hasFullDiskAccess {
                HStack(spacing: 14) {
                    Image(systemName: "lock.shield").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Some folders are off-limits without Full Disk Access").font(.headline)
                        Text("Turn it on so Unearth can identify more of this space. Nothing leaves your Mac either way.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Settings", action: FullDiskAccess.openSettings)
                }
                .padding(16)
                .galleryCard(radius: 12, fill: .hotFill, line: .hotLine)
            }
            if let breakdown = model.breakdown {
                let buckets = breakdown.systemData.filter { $0.value > 0 }.sorted { $0.value > $1.value }
                let largest = Double(max(1, buckets.first?.value ?? 1))
                VStack(spacing: 0) {
                    ForEach(Array(buckets.enumerated()), id: \.element.key) { index, entry in
                        if index > 0 { Divider() }
                        BucketRow(bucket: entry.key, bytes: entry.value, fraction: Double(entry.value) / largest,
                                  contributors: breakdown.bucketContributors[entry.key] ?? [])
                    }
                }
                .galleryCard(radius: 12)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").foregroundStyle(.secondary)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: 940, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BucketRow: View {
    let bucket: SystemDataBucket
    let bytes: Int64
    let fraction: Double
    let contributors: [BucketContributor]
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(CategoryStyle.name(bucket)).font(.headline)
                    Text(CategoryStyle.explanation(bucket))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                SizeLabel(bytes: bytes, size: 15, weight: .semibold)
                if !contributors.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Hide folders" : "Show folders")
                }
            }
            GeometryReader { geometry in
                Capsule()
                    .fill(CategoryStyle.color(.systemData).opacity(0.6))
                    .frame(width: max(3, geometry.size.width * fraction))
            }
            .frame(height: 5)
            if let destination {
                Button(destination.title) { model.sidebarSelection = destination.item }
                    .buttonStyle(.plain).foregroundStyle(.tint).font(.callout)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(contributors.prefix(10), id: \.node) { contributor in
                        HStack(spacing: 10) {
                            Text(model.tree?.path(of: contributor.node) ?? "")
                                .font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            SizeLabel(bytes: contributor.bytes).foregroundStyle(.secondary)
                            Button("Show in Finder") {
                                if let path = model.tree?.path(of: contributor.node) {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.realPath(path))])
                                }
                            }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
    }

    private var destination: (title: String, item: SidebarItem)? {
        switch bucket {
        case .appCaches, .logs, .tempFiles, .deviceUpdates: ("Clean in Caches & junk", .junk)
        case .devCaches, .aiModels, .developerTools, .virtualMachines: ("Clean in Developer & AI", .developer)
        default: nil
        }
    }
}
