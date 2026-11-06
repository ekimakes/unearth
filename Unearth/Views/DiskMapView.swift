import AppKit
import SwiftUI
import UnearthCore

struct DiskMapView: View {
    @Environment(AppModel.self) private var model
    @State private var state = DiskMapState()

    var body: some View {
        if let tree = model.tree {
            ScrollView { DiskMapContent(tree: tree, state: $state) }
                .background(Color.canvas)
                .onAppear { focusAsked(in: tree) }
                .onChange(of: model.diskMapFocus) { focusAsked(in: tree) }
        } else {
            ContentUnavailableView("Measuring your disk…", systemImage: "chart.pie",
                                   description: Text("The map appears when the scan finishes."))
        }
    }
}

extension DiskMapView {
    /// Opens on the folder another screen asked for (the strata), once.
    private func focusAsked(in tree: ScanTree) {
        guard let path = model.diskMapFocus else { return }
        model.diskMapFocus = nil
        if let id = tree.nodeID(forPath: path) { state.focus(on: id, in: tree) }
    }
}

/// The map and the folder list next to it, without the scroll view.
struct DiskMapContent: View {
    let tree: ScanTree
    /// Paths, not node ids: the map stays open while a cleanup triggers a rescan.
    @Binding var state: DiskMapState
    @Environment(AppModel.self) private var model
    @State private var hovered: SunburstSegment?
    @State private var segments: [SunburstSegment] = []
    @State private var segmentsKey: SegmentsKey?

    private struct SegmentsKey: Equatable {
        let scan: UUID
        let focus: NodeID
    }

    private var current: NodeID { state.focus(in: tree) }
    private var key: SegmentsKey { SegmentsKey(scan: tree.id, focus: current) }

    var body: some View {
        let node = tree.node(current)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                if let parent = node.parent { BackButton(destination: displayName(parent), action: goBack) }
                breadcrumb
            }
            HStack(alignment: .top, spacing: 28) {
                SunburstView(segments: currentSegments, focusName: displayName(current), focusBytes: node.totalBytes,
                             hovered: $hovered) { segment in
                    if let id = segment.node, !tree.node(id).children.isEmpty { state.focus(on: id, in: tree) }
                }
                .frame(width: 420, height: 420)
                folderList(node)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: key, initial: true) {
            segments = SunburstView.segments(tree: tree, focus: current)
            segmentsKey = key
            #if DEBUG
            registerForChecks()
            #endif
        }
        .onChange(of: tree.id) { hovered = nil }
        .alert("Move \(state.trashPath.map { ($0 as NSString).lastPathComponent } ?? "this folder") to the Trash?",
               isPresented: Binding(get: { state.trashPath != nil }, set: { if !$0 { state.cancelTrash() } })) {
            Button("Move to Trash", role: .destructive) {
                // Looked up again in the newest scan; nothing moves while a scan is running.
                if !model.isScanning, let latest = model.tree, let item = state.trashItem(in: latest) {
                    Task { await model.moveToTrash([item]) }
                }
                state.cancelTrash()
            }
            Button("Cancel", role: .cancel) { state.cancelTrash() }
        } message: {
            Text("You picked this yourself, so Unearth can't tell whether you'll need it. You can put it back until you empty the Trash.")
        }
    }

    /// Looked up when it's pressed: the keyboard shortcut can hold on to an action from before the last move.
    private func goBack() {
        if let parent = tree.node(current).parent { state.focus(on: parent, in: tree) }
    }

    /// Cached per scan and focus so hovering doesn't rebuild the rings.
    private var currentSegments: [SunburstSegment] {
        segmentsKey == key ? segments : SunburstView.segments(tree: tree, focus: current)
    }

    private var breadcrumb: some View {
        var chain: [NodeID] = []
        var cursor: NodeID? = current
        while let id = cursor {
            chain.insert(id, at: 0)
            cursor = tree.node(id).parent
        }
        return HStack(spacing: 6) {
            ForEach(Array(chain.enumerated()), id: \.element) { index, id in
                if index > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                Button(displayName(id)) { state.focus(on: id, in: tree) }
                    .buttonStyle(.plain)
                    .foregroundStyle(id == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                    .fontWeight(id == current ? .semibold : .regular)
            }
        }
        .font(.title3)
    }

    #if DEBUG
    private func registerForChecks() {
        TimelineProbe.diskMapFolder = { [tree, state = $state] in tree.node(state.wrappedValue.focus(in: tree)).name }
    }
    #endif

    private func folderList(_ node: ScanNode) -> some View {
        let total = Double(max(1, node.totalBytes))
        let shown = Array(node.children.prefix(24))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, id in
                let child = tree.node(id)
                if index > 0 { Divider() }
                HStack(spacing: 10) {
                    Circle()
                        .fill(SunburstView.palette[index % SunburstView.palette.count])
                        .frame(width: 8, height: 8)
                    Text(child.name).lineLimit(1).truncationMode(.middle)
                    if child.isInaccessible {
                        Image(systemName: "lock").font(.caption).foregroundStyle(.secondary)
                            .help("Unearth isn't allowed to look inside this folder.")
                    }
                    Spacer(minLength: 8)
                    Text((Double(child.totalBytes) / total).formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    SizeLabel(bytes: child.totalBytes).frame(minWidth: 70, alignment: .trailing)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
                .onTapGesture { if !child.children.isEmpty { state.focus(on: id, in: tree) } }
                .contextMenu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.realPath(tree.path(of: id)))])
                    }
                    Button("Move to Trash…") { state.askToTrash(id, in: tree) }
                        .disabled(model.isScanning)
                }
            }
            if node.children.count > shown.count {
                Divider()
                Text("\(node.children.count - shown.count) smaller folders")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 7).padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: 460)
        .galleryCard(radius: 12)
    }

    private func displayName(_ id: NodeID) -> String {
        id == tree.rootID ? (model.volumes?.volume(withRole: "System")?.name ?? "Your Mac") : tree.node(id).name
    }
}
