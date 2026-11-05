import AppKit
import SwiftUI
import UnearthCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            CleanUpSettings().tabItem { Label("Clean up", systemImage: "sparkles") }
            LibrarySettings().tabItem { Label("Library", systemImage: "books.vertical") }
            NeverTouchSettings().tabItem { Label("Never touch", systemImage: "hand.raised") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 540, height: 460)
        .tint(.unearth)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Count a file as large from", selection: $model.settings.largeFileThreshold) {
                Text("100 MB").tag(Int64(100_000_000))
                Text("500 MB").tag(Int64(500_000_000))
                Text("1 GB").tag(Int64(1_000_000_000))
                Text("5 GB").tag(Int64(5_000_000_000))
            }
            Picker("Count a file as old after", selection: $model.settings.oldFileAgeDays) {
                Text("3 months").tag(91)
                Text("6 months").tag(182)
                Text("1 year").tag(365)
            }
            Picker("Count a coding project as inactive after", selection: $model.settings.inactiveProjectDays) {
                Text("2 weeks").tag(14)
                Text("30 days").tag(30)
                Text("60 days").tag(60)
                Text("90 days").tag(90)
            }
        }
        .formStyle(.grouped)
    }
}

/// When files count as forgotten, old or unused in the clean-up collections.
struct CleanUpSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var collections = model.collections
        Form {
            Section("Forgotten downloads") {
                Picker("Not opened in", selection: $collections.settings.forgottenDownloadDays) {
                    Text("1 month").tag(30)
                    Text("3 months").tag(90)
                    Text("6 months").tag(182)
                    Text("1 year").tag(365)
                }
            }
            Section("Old screenshots") {
                Picker("Taken more than", selection: $collections.settings.screenshotDays) {
                    Text("1 week ago").tag(7)
                    Text("1 month ago").tag(30)
                    Text("3 months ago").tag(91)
                }
            }
            Section("Big old videos") {
                Picker("At least", selection: $collections.settings.bigVideoBytes) {
                    Text("250 MB").tag(Int64(250_000_000))
                    Text("500 MB").tag(Int64(500_000_000))
                    Text("1 GB").tag(Int64(1_000_000_000))
                    Text("5 GB").tag(Int64(5_000_000_000))
                }
                Picker("Not opened in", selection: $collections.settings.bigVideoDays) {
                    Text("3 months").tag(91)
                    Text("6 months").tag(182)
                    Text("1 year").tag(365)
                }
            }
            Section("Unused apps") {
                Picker("Not opened in", selection: $collections.settings.unusedAppDays) {
                    Text("1 month").tag(30)
                    Text("3 months").tag(90)
                    Text("6 months").tag(182)
                    Text("1 year").tag(365)
                }
            }
            Section("Duplicates") {
                Picker("Look at files from", selection: $collections.settings.duplicateMinBytes) {
                    Text("100 KB").tag(Int64(100_000))
                    Text("1 MB").tag(Int64(1_000_000))
                    Text("10 MB").tag(Int64(10_000_000))
                    Text("100 MB").tag(Int64(100_000_000))
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Folders Unearth must never suggest or remove, whatever any rule says.
struct NeverTouchSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unearth never suggests or removes anything in these folders.")
                .foregroundStyle(.secondary)
            if model.settings.neverTouch.isEmpty {
                ContentUnavailableView("No protected folders", systemImage: "hand.raised",
                                       description: Text("Add folders you want Unearth to leave alone."))
            } else {
                List {
                    ForEach(model.settings.neverTouch, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder")
                            Text(path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                model.settings.neverTouch.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(path)")
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Add Folder…", action: addFolders)
            }
        }
        .padding(20)
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Protect"
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map(\.path).filter { !model.settings.neverTouch.contains($0) }
        model.settings.neverTouch += added
    }
}

/// The folders the Library indexes: the usual places, plus any the user adds, minus any the user leaves out.
struct LibrarySettings: View {
    @Environment(AppModel.self) private var model
    @State private var added = LibraryFolders.added

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unearth keeps a private index of these folders so you can browse and search them. It never leaves this Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Plain rows rather than a List, and scrolling only when they don't fit, so the page renders in snapshots.
            ViewThatFits(in: .vertical) {
                folderRows
                ScrollView { folderRows }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack {
                Spacer()
                Button("Add Folder…", action: addFolders)
            }
            LeftOutFolders()
        }
        .padding(20)
    }

    private var folderRows: some View {
        VStack(spacing: 0) {
            ForEach(Array((model.defaultLibraryFolders + added).enumerated()), id: \.element) { index, path in
                if index > 0 { Divider() }
                row(path) {
                    if added.contains(path) {
                        Button {
                            update(added.filter { $0 != path })
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(path) from the Library")
                    } else {
                        Text("Always").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
            }
        }
    }

    private func row(_ path: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Image(systemName: "folder")
            Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle).help(path)
            Spacer()
            trailing()
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        guard panel.runModal() == .OK else { return }
        update(added + panel.urls.map(\.path).filter { !added.contains($0) })
    }

    private func update(_ folders: [String]) {
        added = folders
        Task { await model.setAddedLibraryFolders(folders) }
    }
}

/// Settings › Library › Leave out of the Library: folders inside the Library that the index skips.
struct LeftOutFolders: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Leave out of the Library")
                .font(.headline)
            Text("Folders full of files you'd never look for, like a game project's assets. Their files leave the Library and its searches; nothing on disk changes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.leftOutFolders.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(model.leftOutFolders.enumerated()), id: \.element) { index, path in
                        if index > 0 { Divider() }
                        HStack {
                            Image(systemName: "eye.slash")
                            Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle).help(path)
                            Spacer()
                            Button {
                                Task { await model.setLeftOutFolders(model.leftOutFolders.filter { $0 != path }) }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Put \(path) back in the Library")
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack {
                Spacer()
                Button("Leave Out a Folder…", action: leaveOut)
            }
        }
    }

    private func leaveOut() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Leave Out"
        guard panel.runModal() == .OK else { return }
        let folders = model.leftOutFolders + panel.urls.map(\.path).filter { !model.leftOutFolders.contains($0) }
        Task { await model.setLeftOutFolders(folders) }
    }
}

struct PrivacySettings: View {
    /// Set once the project has a public home; the app opens it in the browser and never connects itself.
    static let releasesPage: URL? = nil
    @Environment(AppModel.self) private var model
    @State private var confirmingForget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Unearth never connects to the internet", systemImage: "lock.shield").font(.headline)
            Text("No account, no analytics, no crash reports and no update checks. Everything Unearth measures and indexes stays on this Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let page = Self.releasesPage {
                Button("Check for updates") { NSWorkspace.shared.open(page) }
                Text("Opens the releases page in your browser.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Button("Forget Everything…") { confirmingForget = true }
                Text("Erases the Library's index: every file name it knows and all text and objects it read in your images.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Forget everything in the Library?", isPresented: $confirmingForget) {
            Button("Forget Everything", role: .destructive) { Task { await model.forgetLibrary() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your files aren't touched. Unearth builds the index again the next time you open it.")
        }
    }
}
