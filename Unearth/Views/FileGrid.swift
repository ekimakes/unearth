import AppKit
import SwiftUI
import UnearthCore

enum FileLayout: String {
    case grid, list
}

/// How big the cards in a grid are: View › Bigger Cards (⌘+) and Smaller Cards (⌘−).
enum CardSize: String, CaseIterable {
    case small, medium, large

    var side: CGFloat {
        switch self {
        case .small: 104
        case .medium: 132
        case .large: 176
        }
    }

    var bigger: CardSize { self == .small ? .medium : .large }
    var smaller: CardSize { self == .large ? .medium : .small }
}

/// Files as a thumbnail grid or a list, with Finder-style selection: click, ⌘-click, ⇧-click; the arrow keys
/// move it (⇧ extends it), Return and double-click open, Space shows Quick Look, ⌘A selects everything and
/// ⌘⌫ asks to move the selection to the Trash.
struct FileGrid: View {
    static let thumbnailSide: CGFloat = 132

    @Environment(AppModel.self) private var model
    let files: [IndexedFile]
    var layout: FileLayout = .grid
    @Binding var selection: Set<Int64>
    @Binding var trashing: [IndexedFile]
    /// Folders in a Places listing: shown with their icon, opened by going into them.
    var folders: Set<Int64> = []
    var onOpenFolder: (IndexedFile) -> Void = { _ in }
    /// Whether each file says which folder it's in (not needed when they all share one).
    var showsFolder = true
    /// A short note on a file, like why a search matched it.
    var note: (IndexedFile) -> String? = { _ in nil }
    /// Runs when the last file appears, to load the next page.
    var onReachEnd: () -> Void = {}
    /// A tick box on each card, for review pages: clicking it adds or removes just that file.
    var checkboxes = false
    /// Runs when the arrow keys move to a file, so the screen can scroll it into view.
    var onCursor: (Int64) -> Void = { _ in }
    @State private var anchor: Int64?
    @State private var cursor: Int64?
    @State private var width: CGFloat = 0
    @AppStorage("cardSize") private var cardSize: CardSize = .medium

    private var side: CGFloat { cardSize.side }

    var body: some View {
        Group {
            switch layout {
            case .grid:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: side + 12, maximum: side + 12), spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 16) {
                    ForEach(files) { file in
                        cell(file).id(file.id).onAppear { if file.id == files.last?.id { onReachEnd() } }
                    }
                }
            case .list:
                LazyVStack(spacing: 0) {
                    ForEach(files) { file in
                        row(file).id(file.id).onAppear { if file.id == files.last?.id { onReachEnd() } }
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
            move(press.key, extending: press.modifiers.contains(.shift)) ? .handled : .ignored
        }
        .onKeyPress(.return) {
            let chosen = selectedFiles
            guard !chosen.isEmpty else { return .ignored }
            if chosen.count == 1, folders.contains(chosen[0].id) { onOpenFolder(chosen[0]) } else { model.open(chosen) }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "a"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selection = Set(files.map(\.id))
            return .handled
        }
        .onKeyPress(.space) {
            guard let first = selectedFiles.first else { return .ignored }
            model.quickLook(first)
            return .handled
        }
        .onKeyPress(.delete, phases: .down) { press in
            guard press.modifiers.contains(.command), !selection.isEmpty else { return .ignored }
            trashing = selectedFiles
            return .handled
        }
    }

    private var selectedFiles: [IndexedFile] { files.filter { selection.contains($0.id) } }

    /// Moves the selection with an arrow key; with Shift, from the anchor to where the keys are now.
    private func move(_ key: KeyEquivalent, extending: Bool) -> Bool {
        let direction: GridNavigation.Direction = switch key {
        case .leftArrow: .left
        case .rightArrow: .right
        case .upArrow: .up
        default: .down
        }
        let columns = layout == .list ? 1 : GridNavigation.columns(width: width, itemWidth: side + 12, spacing: 14)
        let current = (cursor ?? anchor).flatMap { id in files.firstIndex { $0.id == id } }
            ?? files.lastIndex { selection.contains($0.id) }
        guard let next = GridNavigation.next(from: current, direction: direction, columns: columns, count: files.count) else {
            return false
        }
        let file = files[next]
        if extending, let start = (anchor ?? cursor).flatMap({ id in files.firstIndex { $0.id == id } }) {
            selection = Set(files[GridNavigation.range(anchor: start, cursor: next)].map(\.id))
        } else {
            selection = [file.id]
            anchor = file.id
        }
        cursor = file.id
        onCursor(file.id)
        return true
    }

    // MARK: - Cells

    private func cell(_ file: IndexedFile) -> some View {
        let selected = selection.contains(file.id)
        return FileCard(file: file, side: side, selected: selected, isFolder: folders.contains(file.id), detail: detail(file),
                        note: note(file))
            .overlay(alignment: .topTrailing) {
                if checkboxes { checkbox(file, selected: selected).padding(6) }
            }
            .contentShape(Rectangle())
            .onTapGesture { click(file) }
            .contextMenu { menu(for: file) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            .accessibilityActions { actions(for: file) }
            .help(file.name)
    }

    private func row(_ file: IndexedFile) -> some View {
        let selected = selection.contains(file.id)
        return FileRow(file: file, selected: selected, isFolder: folders.contains(file.id), note: note(file), date: file.added)
            .contentShape(Rectangle())
            .onTapGesture { click(file) }
            .contextMenu { menu(for: file) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            .accessibilityActions { actions(for: file) }
    }

    /// What VoiceOver offers on each file.
    @ViewBuilder
    private func actions(for file: IndexedFile) -> some View {
        Button("Open") { if folders.contains(file.id) { onOpenFolder(file) } else { model.open([file]) } }
        Button("Quick Look") { model.quickLook(file) }
        Button("Move to Trash") { trashing = [file] }
    }

    private func checkbox(_ file: IndexedFile, selected: Bool) -> some View {
        Button {
            if selection.contains(file.id) { selection.remove(file.id) } else { selection.insert(file.id) }
            anchor = file.id
        } label: {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(selected ? .white : Color.secondaryInk, selected ? Color.unearth : Color.surface)
                .background(Circle().fill(selected ? Color.unearth : Color.surface).padding(2))
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel(selected ? "Selected" : "Not selected")
    }

    private func detail(_ file: IndexedFile) -> String {
        let size = file.bytes > 0 ? ByteFormatting.string(file.bytes) : nil
        if folders.contains(file.id) { return size ?? "Folder" }
        return [size, showsFolder ? (file.parent as NSString).lastPathComponent : nil].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func menu(for file: IndexedFile) -> some View {
        let targets = selection.contains(file.id) ? selectedFiles : [file]
        FileActions(files: targets)
        Divider()
        Button("Move to Trash…") { trashing = targets }
    }

    // MARK: - Clicks

    private func click(_ file: IndexedFile) {
        if NSApp.currentEvent?.clickCount == 2 {
            if folders.contains(file.id) { onOpenFolder(file) } else { model.open([file]) }
            return
        }
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) || (checkboxes && !modifiers.contains(.shift)) {
            if selection.contains(file.id) { selection.remove(file.id) } else { selection.insert(file.id) }
            anchor = file.id
        } else if modifiers.contains(.shift), let anchor, let start = files.firstIndex(where: { $0.id == anchor }),
                  let end = files.firstIndex(where: { $0.id == file.id }) {
            selection = Set(files[min(start, end)...max(start, end)].map(\.id))
        } else {
            selection = [file.id]
            anchor = file.id
        }
    }
}

/// A file as a card: its thumbnail, its name and a line of detail, tinted when selected.
struct FileCard: View {
    let file: IndexedFile
    let side: CGFloat
    var selected = false
    /// A folder in a Places listing, shown with its Finder icon.
    var isFolder = false
    let detail: String
    /// A short note on the thumbnail, like why a search matched the file.
    var note: String?
    /// Whether the card is `height(side:)` tall whatever its name, so a row of them lines up.
    var fillsHeight = false

    /// A card's height with a two-line name.
    nonisolated static func height(side: CGFloat) -> CGFloat { side + 66 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
                .overlay(alignment: .topLeading) {
                    if let note {
                        Text(note)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                            .padding(6)
                            .frame(maxWidth: side, alignment: .leading)
                    }
                }
            Text(file.name)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: side, height: fillsHeight ? Self.height(side: side) - 12 : nil, alignment: .topLeading)
        .padding(6)
        .background(selected ? Color.unearth.opacity(0.12) : Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            // A thin line in the file's kind color; the selection in Unearth orange.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.unearth.opacity(0.8) : file.kind.color.opacity(0.28), lineWidth: selected ? 2 : 1)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if isFolder {
            Image(nsImage: ThumbnailCache.shared.folderIcon(file.path))
                .resizable()
                .scaledToFit()
                .padding(side * 0.1)
                .frame(width: side, height: side)
        } else {
            FileThumbnail(file: file, side: side)
        }
    }
}

/// A file as a list row: its thumbnail, name, kind, a date and its size.
struct FileRow: View {
    nonisolated static let height: CGFloat = 38
    static let thumbnailSide: CGFloat = 28

    let file: IndexedFile
    var selected = false
    var isFolder = false
    var note: String?
    let date: Date

    var body: some View {
        HStack(spacing: 12) {
            if isFolder {
                Image(nsImage: ThumbnailCache.shared.folderIcon(file.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
            } else {
                FileThumbnail(file: file, side: Self.thumbnailSide)
            }
            Text(file.name).lineLimit(1).truncationMode(.middle)
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(isFolder ? "Folder" : file.kind.title)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(date.formatted(date: .abbreviated, time: .omitted))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Group {
                if file.bytes > 0 { SizeLabel(bytes: file.bytes) } else { Text("—").foregroundStyle(.tertiary) }
            }
            .frame(width: 80, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(selected ? Color.unearth.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// What can be done with the selected files, at the bottom of a browse screen.
struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    let files: [IndexedFile]
    @Binding var trashing: [IndexedFile]
    @Binding var selection: Set<Int64>
    /// Where the files are, when whole folders or sources were picked: "in 3 folders".
    var note: String?

    var body: some View {
        HStack(spacing: 10) {
            Text((files.count == 1 ? "1 selected" : "\(files.count.formatted()) selected") + (note.map { " \($0)" } ?? ""))
                .font(.headline)
            SizeLabel(bytes: files.reduce(0) { $0 + $1.bytes }).foregroundStyle(.secondary)
            Button("Deselect") { selection = [] }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            Spacer()
            Menu("Actions") { FileActions(files: files) }
                .fixedSize()
            Button("Move to Trash…") { trashing = files }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.trashProgress != nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Asks before files the user picked go to the Trash, then sends them through the cleanup engine.
/// The size it names is the space on this Mac, measured first: iCloud-only files take none, and a folder the
/// disk scan didn't cover is measured rather than shown as empty.
struct TrashConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var files: [IndexedFile]
    /// Files from a clean-up collection go with its explanation; others as files the user picked.
    var collection: CollectionKind?
    @State private var measured: Measured?

    private struct Measured: Equatable {
        let paths: [String]
        let bytes: Int64
        let cloudOnly: Int
    }

    func body(content: Content) -> some View {
        content
            .task(id: files.map(\.path)) {
                guard !files.isEmpty else { return }
                let paths = files.map(\.path)
                let cloudOnly = files.filter(\.isCloudOnly).count
                let bytes = await Task.detached { paths.reduce(Int64(0)) { $0 + DiskUsage.onDisk($1) } }.value
                guard !Task.isCancelled else { return }
                measured = Measured(paths: paths, bytes: bytes, cloudOnly: cloudOnly)
            }
            .alert(title, isPresented: Binding(
                get: { !files.isEmpty && measured?.paths == files.map(\.path) },
                set: { if !$0 { files = []; measured = nil } })) {
                Button("Move to Trash", role: .destructive) {
                    let chosen = files
                    let collection = collection
                    Task {
                        if let collection {
                            await model.trash(collection: collection, files: chosen)
                        } else {
                            await model.moveFilesToTrash(chosen)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(message)
            }
    }

    private var message: String {
        let size = ByteFormatting.string(measured?.bytes ?? 0)
        let one = files.count == 1
        var text = one ? "It takes up \(size) on this Mac." : "They take up \(size) on this Mac."
        if let cloudOnly = measured?.cloudOnly, cloudOnly > 0 {
            text += one ? " It's only in iCloud, so the Trash won't free space here."
                        : " \(cloudOnly.formatted()) of them are only in iCloud and free no space here."
        }
        return text + (one ? " You can put it back from the Trash until you empty it."
                           : " You can put them back from the Trash until you empty it.")
    }

    private var title: String {
        files.count == 1 ? "Move “\(files[0].name)” to the Trash?" : "Move \(files.count.formatted()) items to the Trash?"
    }
}

extension View {
    func trashConfirmation(_ files: Binding<[IndexedFile]>, collection: CollectionKind? = nil) -> some View {
        modifier(TrashConfirmation(files: files, collection: collection))
    }
}
