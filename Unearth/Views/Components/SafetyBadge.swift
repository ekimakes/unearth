import SwiftUI
import UnearthCore

struct SafetyBadge: View {
    let safety: SafetyLevel

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(safety == .careful ? Color.clear : color.opacity(0.14), in: Capsule())
            .overlay {
                if safety == .careful { Capsule().strokeBorder(color.opacity(0.8), lineWidth: 1) }
            }
            .accessibilityLabel("Safety: \(label)")
    }

    private var label: String {
        switch safety {
        case .safe: "Safe"
        case .review: "Review"
        case .careful: "Careful"
        }
    }

    private var color: Color {
        switch safety {
        case .safe: .green
        case .review: .orange
        case .careful: .red
        }
    }
}

struct PermanentBadge: View {
    var body: some View {
        Text("Can't be undone")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(.secondary)
            .overlay { Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 1) }
    }
}
