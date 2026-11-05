import AppKit
import SwiftUI
import UnearthCore

/// First launch: what Unearth promises, then the optional Full Disk Access step.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var page = 0
    let onFinish: () -> Void

    var body: some View {
        Group {
            if page == 0 { WelcomePage { page = 1 } } else { AccessPage(onFinish: onFinish) }
        }
        .frame(width: 560)
        .tint(.unearth)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.hasFullDiskAccess = FullDiskAccess.isGranted()
        }
    }
}

struct WelcomePage: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Unearth").font(.largeTitle.weight(.bold))
                Text("Find anything. Free up the rest.").font(.title3).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 18) {
                Promise(symbol: "lock.shield", text: "Nothing leaves your Mac. Unearth never connects to the internet.")
                Promise(symbol: "arrow.uturn.backward.circle", text: "Nothing is deleted without your OK, and everything goes to the Trash first.")
                Promise(symbol: "gift", text: "Free, forever.")
            }
            HStack {
                Spacer()
                Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(36)
    }
}

struct AccessPage: View {
    @Environment(AppModel.self) private var model
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("See everything (optional)").font(.largeTitle.weight(.bold))
                Text("Full Disk Access lets Unearth measure Mail, Messages, iPhone backups and other apps' data. Without it, Unearth still works but some space shows as Not identified. macOS may also ask about your Desktop, Documents and Downloads folders.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(model.hasFullDiskAccess ? "Full Disk Access is on" : "Full Disk Access is off",
                  systemImage: model.hasFullDiskAccess ? "checkmark.circle.fill" : "circle.dashed")
                .font(.headline)
                .foregroundStyle(model.hasFullDiskAccess ? Color.green : Color.secondary)
            HStack {
                if !model.hasFullDiskAccess {
                    Button("Open System Settings", action: FullDiskAccess.openSettings)
                        .controlSize(.large)
                }
                Spacer()
                Button(model.hasFullDiskAccess ? "Start scanning" : "Continue without it", action: onFinish)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(36)
    }
}

private struct Promise: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            Text(text).font(.title3).fixedSize(horizontal: false, vertical: true)
        }
    }
}
