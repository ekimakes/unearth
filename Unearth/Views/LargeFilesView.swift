import SwiftUI
import UnearthCore

struct LargeFilesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Picker("At least", selection: $model.settings.largeFileThreshold) {
                    Text("100 MB").tag(Int64(100_000_000))
                    Text("500 MB").tag(Int64(500_000_000))
                    Text("1 GB").tag(Int64(1_000_000_000))
                    Text("5 GB").tag(Int64(5_000_000_000))
                }
                .fixedSize()
                Picker("Not opened in", selection: $model.settings.oldFileAgeDays) {
                    Text("Any time").tag(0)
                    Text("3 months").tag(91)
                    Text("6 months").tag(182)
                    Text("1 year").tag(365)
                }
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()
            CleanupSectionView(section: .largeFiles)
        }
    }
}
