import AppKit
import SwiftUI
import UnearthCore

/// A square checkbox drawn by SwiftUI itself.
struct CheckBox: View {
    let isOn: Bool
    var isEnabled = true
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 17))
                .foregroundStyle(isOn && isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(isOn ? "Selected" : "Not selected")
        .accessibilityAddTraits(.isToggle)
    }
}

struct CleanupItemRow: View {
    let item: CleanupItem
    @Environment(AppModel.self) private var model
    @State private var expanded = false
    @State private var confirmingTool = false

    private var isSelectable: Bool { item.action == .trash && item.blockedReason == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if isSelectable {
                    CheckBox(isOn: model.selection.contains(item.id)) { model.toggle(item.id) }
                } else {
                    Image(systemName: leadingSymbol)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 17)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                    if let note = note {
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                SafetyBadge(safety: item.safety)
                if item.isPermanent { PermanentBadge() }
                SizeLabel(bytes: item.bytes)
                    .frame(minWidth: 72, alignment: .trailing)
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
                .accessibilityLabel(expanded ? "Hide details" : "Show details")
            }

            if case .report(let guidance) = item.action {
                Text(guidance).font(.callout).foregroundStyle(.secondary).padding(.leading, 29)
            }
            if item.blockedReason == .needsFullDiskAccess {
                Button("Open Full Disk Access settings", action: FullDiskAccess.openSettings)
                    .buttonStyle(.bordered).controlSize(.small).padding(.leading, 29)
            } else if item.isPermanent {
                Button("Run cleanup…") { confirmingTool = true }
                    .buttonStyle(.bordered).controlSize(.small).padding(.leading, 29)
            }
            if expanded { details.padding(.leading, 29) }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .alert("Permanently remove \(item.title)?", isPresented: $confirmingTool) {
            Button("Remove", role: .destructive) { Task { await model.runTool(item) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(toolName) deletes this directly. It can't be undone or restored from the Trash.")
        }
    }

    private var note: String? {
        switch item.blockedReason {
        case .appRunning(let name): "Quit \(name) first"
        case .neverTouch: "On your never-touch list"
        case .needsFullDiskAccess: "Needs Full Disk Access to measure"
        case nil: item.subtitle
        }
    }

    private var leadingSymbol: String {
        if item.blockedReason != nil { return "lock" }
        if item.isPermanent { return "wrench.and.screwdriver" }
        return "info.circle"
    }

    private var toolName: String {
        if case .tool(let command) = item.action { return command.toolName }
        return "The tool"
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            QuestionLine(question: "What is this?", answer: item.explanation.what)
            QuestionLine(question: "Will it come back?", answer: item.explanation.regrows)
            QuestionLine(question: "Safe to delete?", answer: item.explanation.safeToDelete)
            ForEach(item.paths.prefix(6), id: \.self) { path in
                HStack(spacing: 8) {
                    Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.realPath(path))])
                    }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                    if item.section == .largeFiles {
                        Button("Quick Look") { model.previewURL = URL(fileURLWithPath: model.realPath(path)) }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                    }
                }
            }
            if item.paths.count > 6 {
                Text("and \(item.paths.count - 6) more").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct QuestionLine: View {
    let question: String
    let answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(question).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(answer).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum GroupStyle {
    static func symbol(_ group: String) -> String {
        switch group {
        case "Browser caches": "globe"
        case "App caches": "app.badge"
        case "Apple app caches": "applelogo"
        case "App web caches": "network"
        case "Logs & crash reports": "doc.text"
        case "Mail attachment copies": "paperclip"
        case "iPhone & iPad updates", "iPhone & iPad backups": "iphone"
        case "Installers in Downloads": "shippingbox"
        case "Archives in Downloads": "doc.zipper"
        case "Temporary files": "clock"
        case "Trash": "trash"
        case "Time Machine": "clock.arrow.circlepath"
        case "Xcode build files": "hammer"
        case "Xcode archives": "archivebox"
        case "Device support files": "cable.connector"
        case "Simulators": "iphone.gen3"
        case "Package manager caches": "cube.box"
        case "Browser automation": "theatermasks"
        case "AI models": "brain"
        case "Virtual machines & containers": "server.rack"
        case "Build files in inactive projects": "folder.badge.gearshape"
        case "Photos & videos": "photo.on.rectangle"
        case "Other large files": "doc"
        case "Picked by you": "hand.point.up.left"
        default: "folder"
        }
    }
}
