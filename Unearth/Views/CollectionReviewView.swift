import AppKit
import SwiftUI
import UnearthCore

/// Exact copies, or photos that only look alike: the two tabs of Duplicates.
enum DuplicatesTab: Hashable {
    case copies, lookAlikes
}

/// One clean-up collection: what it is, what's in it, and moving what you pick to the Trash.
struct CollectionReviewView: View {
    @Environment(AppModel.self) private var model
    let kind: CollectionKind
    @State private var tab: DuplicatesTab
    @State private var groups: [DuplicateGroup] = []
    @State private var selection: Set<Int64> = []
    @State private var lookAlikeSelection: Set<Int64> = []
    @State private var trashing: [IndexedFile] = []
    @State private var uninstalling: InstalledApp?

    init(kind: CollectionKind) {
        self.kind = kind
        _tab = State(initialValue: kind == .lookAlikes ? .lookAlikes : .copies)
    }

    var body: some View {
        ScrollView {
            CollectionReviewContent(kind: kind, tab: $tab, groups: $groups, selection: $selection,
                                    lookAlikeSelection: $lookAlikeSelection, uninstalling: $uninstalling, trashing: $trashing)
        }
        .background(Color.canvas)
        .safeAreaInset(edge: .bottom) {
            if !picked.isEmpty {
                CollectionTrashBar(files: picked, freed: freed, trashing: $trashing, deselect: deselect)
            }
        }
        .trashConfirmation($trashing, collection: trashKind)
        .alert(uninstalling.map { "Uninstall \($0.name)?" } ?? "", isPresented: Binding(
            get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } })) {
            Button("Move to Trash", role: .destructive) {
                guard let app = uninstalling else { return }
                Task { await model.uninstall(app) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(uninstalling.map(UninstallText.message) ?? "")
        }
        .onAppear(perform: load)
        .onChange(of: model.collections.duplicates) { load() }
    }

    private var isDuplicatesPage: Bool { kind == .duplicates || kind == .lookAlikes }

    private var trashKind: CollectionKind {
        isDuplicatesPage ? (tab == .copies ? .duplicates : .lookAlikes) : kind
    }

    /// What Move to Trash would take: for duplicates never a kept copy, and nothing from a group whose kept
    /// copy is gone.
    private var picked: [IndexedFile] {
        let collections = model.collections
        switch (isDuplicatesPage, tab) {
        case (true, .copies):
            return groups.flatMap { $0.trashable(selection, exists: { FileManager.default.fileExists(atPath: $0) }) }
        case (true, .lookAlikes):
            return collections.lookAlikes.flatMap(\.files).filter { lookAlikeSelection.contains($0.id) }
        default:
            return (collections.files[kind] ?? []).filter { selection.contains($0.id) }
        }
    }

    /// The space the picked files take, leaving out copies that share their storage with the kept one.
    private var freed: Int64 {
        let clones = isDuplicatesPage && tab == .copies ? Set(groups.flatMap(\.clones)) : []
        return picked.filter { !clones.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    private func deselect() {
        if isDuplicatesPage, tab == .lookAlikes { lookAlikeSelection = [] } else { selection = [] }
    }

    /// Duplicates come with their extra copies picked; everything else starts with nothing picked. A refresh
    /// while the page is open keeps the user's choices.
    private func load() {
        guard isDuplicatesPage else { return }
        if groups.isEmpty {
            groups = model.collections.duplicates
            selection = groups.reduce(into: []) { $0.formUnion($1.defaultSelection()) }
        } else {
            (groups, selection) = DuplicateGroup.merge(model.collections.duplicates, keeping: groups, selection: selection)
        }
    }
}

/// A collection's page without its scroll view, so it can also be rendered to an image.
struct CollectionReviewContent: View {
    @Environment(AppModel.self) private var model
    let kind: CollectionKind
    @Binding var tab: DuplicatesTab
    @Binding var groups: [DuplicateGroup]
    @Binding var selection: Set<Int64>
    @Binding var lookAlikeSelection: Set<Int64>
    @Binding var uninstalling: InstalledApp?
    @Binding var trashing: [IndexedFile]

    /// Duplicates' look-alike tab speaks for look-alikes.
    private var shown: CollectionKind {
        kind == .duplicates || kind == .lookAlikes ? (tab == .copies ? .duplicates : .lookAlikes) : kind
    }

    var body: some View {
        let collections = model.collections
        VStack(alignment: .leading, spacing: 20) {
            CollectionHeader(kind: shown, summary: collections.summaries[shown], settings: collections.settings)
            switch kind {
            case .duplicates, .lookAlikes:
                TabPills(selection: $tab, tabs: [
                    (.copies, "Exact copies", collections.duplicates.count),
                    (.lookAlikes, "Look-alike photos", collections.lookAlikes.count),
                ])
                if tab == .copies {
                    copies
                } else {
                    lookAlikes
                }
            case .unusedApps:
                UnusedAppsList(uninstalling: $uninstalling)
            default:
                files(collections.files[kind] ?? [])
            }
        }
        .padding(EdgeInsets(top: 22, leading: 28, bottom: 32, trailing: 28))
        .frame(maxWidth: 1_160, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func files(_ files: [IndexedFile]) -> some View {
        if files.isEmpty {
            empty
        } else {
            HStack {
                Text(files.count == 1 ? "1 file" : "\(files.count.formatted()) files")
                    .foregroundStyle(Color.secondaryInk)
                Spacer()
                Button(selection.isSuperset(of: files.map(\.id)) ? "Deselect all" : "Select all") {
                    selection = selection.isSuperset(of: files.map(\.id)) ? [] : Set(files.map(\.id))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.secondaryInk)
            }
            .font(.callout)
            FileGrid(files: files, selection: $selection, trashing: $trashing, note: note, checkboxes: true)
        }
    }

    /// Why a file is here, on its card: when it was last opened, or taken.
    private func note(_ file: IndexedFile) -> String? {
        switch kind {
        case .oldScreenshots: (file.created ?? file.added).formatted(.relative(presentation: .named))
        default: nil
        }
    }

    @ViewBuilder
    private var copies: some View {
        if groups.isEmpty {
            empty
        } else {
            ForEach($groups) { $group in
                DuplicateGroupCard(group: $group, selection: $selection)
            }
        }
    }

    @ViewBuilder
    private var lookAlikes: some View {
        let groups = model.collections.lookAlikes
        if groups.isEmpty {
            empty
        } else {
            Text("Nothing is picked for you. The best shot of each group is marked; keep the ones you like.")
                .font(.callout)
                .foregroundStyle(Color.secondaryInk)
            ForEach(groups) { group in
                LookAlikeGroupCard(group: group, selection: $lookAlikeSelection)
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView(model.collections.isWorking ? "Still looking" : "Nothing here right now", systemImage: "sparkles",
                               description: Text("Unearth looks again after every scan and whenever your files change."))
            .frame(maxWidth: .infinity, minHeight: 240)
    }
}

/// The top of a collection's page: its size, what's in it, and the three plain answers.
struct CollectionHeader: View {
    let kind: CollectionKind
    let summary: CollectionsModel.Summary?
    let settings: CollectionSettings

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ByteFormatting.string(summary?.bytes ?? 0))
                    .font(.size(34, weight: .bold))
                    .foregroundStyle(Color.ink)
                Text(kind.detail(count: summary?.count ?? 0, settings: settings))
                    .foregroundStyle(Color.secondaryInk)
            }
            .frame(minWidth: 200, alignment: .leading)
            HStack(alignment: .top, spacing: 18) {
                answer("What is this?", kind.explanation.what)
                answer("Will it come back?", kind.explanation.regrows)
                answer("Is it safe?", kind.explanation.safeToDelete)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .galleryCard(radius: 16)
    }

    private func answer(_ question: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(question).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink)
            Text(text).font(.system(size: 12)).foregroundStyle(Color.secondaryInk).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The selection's count and size, and Move to Trash, at the bottom of a review page.
struct CollectionTrashBar: View {
    let files: [IndexedFile]
    let freed: Int64
    @Binding var trashing: [IndexedFile]
    let deselect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(files.count == 1 ? "1 selected" : "\(files.count.formatted()) selected").font(.headline)
            SizeLabel(bytes: freed).foregroundStyle(Color.secondaryInk)
            Button("Deselect", action: deselect)
                .buttonStyle(.plain)
                .foregroundStyle(Color.secondaryInk)
            Spacer()
            Button("Move to Trash…") { trashing = files }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Two or three choices as pills, the chosen one raised: the Gallery's segmented control.
struct TabPills<Tab: Hashable>: View {
    @Binding var selection: Tab
    let tabs: [(tab: Tab, title: String, count: Int)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.tab) { item in
                let chosen = item.tab == selection
                Button { selection = item.tab } label: {
                    HStack(spacing: 6) {
                        Text(item.title)
                        Text(item.count.formatted())
                            .monospacedDigit()
                            .foregroundStyle(Color.secondaryInk)
                    }
                    .font(.system(size: 12.5, weight: chosen ? .semibold : .regular))
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background {
                        if chosen {
                            Capsule().fill(Color.surface).shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.hairline.opacity(0.7), in: Capsule())
    }
}

// MARK: - Duplicates

/// Copies of one file side by side: the kept one marked, the extras picked, clones marked as freeing nothing.
struct DuplicateGroupCard: View {
    static let side: CGFloat = 104
    @Binding var group: DuplicateGroup
    @Binding var selection: Set<Int64>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(group.files.count) copies of “\(group.files[0].name)”")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Text(ByteFormatting.string(group.files[0].bytes) + " each")
                    .monospacedDigit()
                    .foregroundStyle(Color.secondaryInk)
                Spacer()
                Text(group.extraBytes > 0 ? "Frees \(ByteFormatting.string(group.extraBytes))" : "Frees nothing")
                    .monospacedDigit()
                    .foregroundStyle(Color.secondaryInk)
            }
            .font(.system(size: 12))
            // A plain row when the copies fit; it scrolls only when they don't.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) { ForEach(group.files) { file in copy(file) } }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) { ForEach(group.files) { file in copy(file) } }
                }
            }
        }
        .padding(16)
        .galleryCard()
    }

    private func copy(_ file: IndexedFile) -> some View {
        let kept = file.id == group.keep
        let clone = group.clones.contains(file.id)
        let selected = selection.contains(file.id)
        return VStack(alignment: .leading, spacing: 5) {
            ThumbnailFill(file: file, side: Self.side)
                .frame(width: Self.side, height: Self.side)
                .background(Color.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.unearth : Color.hairline, lineWidth: selected ? 2 : 1)
                }
                .overlay(alignment: .bottomLeading) {
                    if kept { badge("Keep", fill: Color.ink, text: Color.canvas) }
                    else if clone { badge("Frees nothing", fill: Color.surface, text: Color.secondaryInk) }
                }
                .overlay(alignment: .topTrailing) {
                    if !kept { tick(file, selected: selected) }
                }
            Text((file.parent as NSString).lastPathComponent)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .help(file.path)
            Text(file.added.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 11))
                .foregroundStyle(Color.secondaryInk)
            if !kept {
                Button("Keep this one") { keep(file) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondaryInk)
            }
        }
        .frame(width: Self.side, alignment: .leading)
        .contextMenu { FileActions(files: [file]) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.name) in \((file.parent as NSString).lastPathComponent)\(kept ? ", kept" : selected ? ", selected" : "")")
    }

    private func badge(_ text: String, fill: Color, text color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(fill, in: Capsule())
            .padding(6)
    }

    private func tick(_ file: IndexedFile, selected: Bool) -> some View {
        Button {
            if selected { selection.remove(file.id) } else { selection.insert(file.id) }
        } label: {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(selected ? Color.unearth : Color.secondaryInk)
                .background(Circle().fill(Color.surface).padding(2))
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel(selected ? "Selected" : "Not selected")
    }

    /// Keeping another copy picks this group's extras again, around the new one.
    private func keep(_ file: IndexedFile) {
        selection.subtract(group.files.map(\.id))
        group.keep = file.id
        selection.formUnion(group.defaultSelection())
    }
}

/// Photos that look alike, with the best shot marked. Nothing is picked for the user.
struct LookAlikeGroupCard: View {
    static let side: CGFloat = 120
    let group: LookAlikeGroup
    @Binding var selection: Set<Int64>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(group.files.count) similar photos")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                if let first = group.files.first {
                    Text((first.created ?? first.added).formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryInk)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { ForEach(group.files) { file in photo(file) } }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) { ForEach(group.files) { file in photo(file) } }
                }
            }
        }
        .padding(16)
        .galleryCard()
    }

    private func photo(_ file: IndexedFile) -> some View {
        let selected = selection.contains(file.id)
        return VStack(alignment: .leading, spacing: 5) {
            ThumbnailFill(file: file, side: Self.side)
                .frame(width: Self.side, height: Self.side)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.unearth : Color.hairline, lineWidth: selected ? 2 : 1)
                }
                .overlay(alignment: .bottomLeading) {
                    if file.id == group.best {
                        Label("Best shot", systemImage: "star.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.ink.opacity(0.78), in: Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Button {
                        if selected { selection.remove(file.id) } else { selection.insert(file.id) }
                    } label: {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(selected ? Color.unearth : Color.secondaryInk)
                            .background(Circle().fill(Color.surface).padding(2))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .accessibilityLabel(selected ? "Selected" : "Not selected")
                }
            Text(file.name)
                .font(.system(size: 12))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            SizeLabel(bytes: file.bytes, size: 11).foregroundStyle(Color.secondaryInk)
        }
        .frame(width: Self.side, alignment: .leading)
        .contextMenu { FileActions(files: [file]) }
    }
}

// MARK: - Unused apps

/// Apps nobody has opened in a while, each with what it keeps on the Mac and how to remove it.
struct UnusedAppsList: View {
    @Environment(AppModel.self) private var model
    @Binding var uninstalling: InstalledApp?

    var body: some View {
        let collections = model.collections
        VStack(alignment: .leading, spacing: 14) {
            if collections.apps.isEmpty {
                ContentUnavailableView("No unused apps", systemImage: "app.dashed",
                                       description: Text("Every app was opened in the last \(CollectionKind.age(collections.settings.unusedAppDays))."))
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                rows(collections.apps)
            }
            if !collections.undatedApps.isEmpty {
                SectionHeader(title: "Not opened since Unearth started looking")
                Text("Spotlight has no record of these being opened, so Unearth doesn't count them as unused.")
                    .font(.callout)
                    .foregroundStyle(Color.secondaryInk)
                rows(collections.undatedApps)
            }
        }
    }

    private func rows(_ apps: [InstalledApp]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                if index > 0 { Divider().padding(.leading, 62) }
                AppRow(app: app, uninstall: { uninstalling = app })
            }
        }
        .galleryCard()
    }
}

struct AppRow: View {
    let app: InstalledApp
    let uninstall: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(nsImage: ThumbnailCache.shared.folderIcon(app.path))
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink)
                    Text(app.lastUsed.map { "Last opened \($0.formatted(.relative(presentation: .named)))" }
                         ?? "Not opened since Unearth started looking")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryInk)
                }
                Spacer(minLength: 12)
                SizeLabel(bytes: app.movableBytes, size: 13, weight: .semibold).foregroundStyle(Color.ink)
                    .frame(minWidth: 70, alignment: .trailing)
                action.frame(minWidth: 150, alignment: .trailing)
            }
            if !app.leftovers.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(app.leftovers, id: \.path) { leftover in
                            HStack {
                                Text(leftover.path)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                    .foregroundStyle(leftover.movable ? Color.ink : Color.secondaryInk)
                                if !leftover.movable {
                                    Text("Left behind").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.secondaryInk)
                                }
                                Spacer()
                                SizeLabel(bytes: leftover.bytes, size: 11).foregroundStyle(Color.secondaryInk)
                            }
                            .help(leftover.movable ? leftover.path
                                  : "Outside your home folder. Unearth leaves it alone; the app's own uninstaller removes it.")
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(leftoverSummary).font(.system(size: 12)).foregroundStyle(Color.secondaryInk)
                }
                .padding(.leading, 48)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var leftoverSummary: String {
        let movable = app.leftovers.filter(\.movable)
        let behind = app.leftovers.count - movable.count
        var text = movable.count == 1 ? "1 thing it keeps in your home folder" : "\(movable.count) things it keeps in your home folder"
        if behind > 0 { text += ", \(behind) left behind elsewhere" }
        return text
    }

    @ViewBuilder
    private var action: some View {
        if let vendor = app.vendorFolder {
            Text("Use \(vendor)'s uninstaller")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryInk)
                .multilineTextAlignment(.trailing)
        } else if RunningApps.isRunning(app.bundleID) {
            Text("Quit \(app.name) first")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryInk)
        } else {
            Button("Uninstall…", action: uninstall)
        }
    }
}

/// What the uninstall confirmation says: everything that goes, what stays, and why a password may be asked for.
enum UninstallText {
    static func message(_ app: InstalledApp) -> String {
        let movable = app.leftovers.filter(\.movable)
        let behind = app.leftovers.filter { !$0.movable }
        var lines = ["Moves \(app.name) to the Trash" + (movable.isEmpty ? "." : ", with what it keeps in your home folder:")]
        lines += movable.map { "• " + Self.place($0.path) }
        if !behind.isEmpty {
            lines.append("Left behind, outside your home folder: " + behind.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ") + ".")
        }
        if app.needsAdmin {
            lines.append("macOS will ask for an administrator's password, because \(app.name) was installed for all users of this Mac.")
        }
        lines.append("You can put everything back from the Trash until you empty it.")
        return lines.joined(separator: "\n")
    }

    /// "Caches › com.example.Example".
    private static func place(_ path: String) -> String {
        let parts = path.split(separator: "/").suffix(2)
        return parts.joined(separator: " › ")
    }
}
