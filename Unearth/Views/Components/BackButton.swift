import SwiftUI

/// The way back out of a folder or a tile, in the same spot on every screen. ⌘[ works too, as in Finder and Safari.
struct BackButton: View {
    /// Where it leads, for the tooltip and VoiceOver.
    let destination: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Back", systemImage: "chevron.left")
        }
        .buttonStyle(.bordered)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back to \(destination)")
        .accessibilityLabel("Back to \(destination)")
        #if DEBUG
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { TimelineProbe.backButton = $0 }
        .onDisappear { TimelineProbe.backButton = nil }
        #endif
    }
}
