import SwiftUI
import UnearthCore

@main
struct UnearthApp: App {
    @State private var model = AppModel(options: LaunchOptions.parse())
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("cardSize") private var cardSize: CardSize = .medium

    var body: some Scene {
        WindowGroup("Unearth") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                .sheet(isPresented: showingOnboarding) {
                    OnboardingView {
                        onboarded = true
                        Task { await model.startScan() }
                    }
                    .environment(model)
                    .interactiveDismissDisabled()
                }
                .task {
                    // The first scan waits for onboarding, so macOS's folder prompts follow an explanation.
                    if onboarded || model.options.skipOnboarding {
                        await model.open()
                    }
                    #if DEBUG
                    if let directory = model.options.snapshotDirectory {
                        await DebugSnapshots.run(model, directory: directory)
                    }
                    #endif
                }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Search Files") { model.requestSearchFocus() }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(before: .toolbar) {
                Button("Bigger Cards") { cardSize = cardSize.bigger }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(cardSize == .large)
                Button("Smaller Cards") { cardSize = cardSize.smaller }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(cardSize == .small)
                Divider()
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }

    private var showingOnboarding: Binding<Bool> {
        Binding(get: { !onboarded && !model.options.skipOnboarding }, set: { _ in })
    }
}
