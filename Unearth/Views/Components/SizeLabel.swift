import SwiftUI
import UnearthCore

/// Sizes are the heart of the app, so they get the rounded face and aligned digits everywhere.
struct SizeLabel: View {
    let bytes: Int64
    var size: CGFloat = 13
    var weight: Font.Weight = .medium

    var body: some View {
        Text(ByteFormatting.string(bytes))
            .font(.system(size: size, weight: weight, design: .rounded))
            .monospacedDigit()
    }
}
