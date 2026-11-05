import AppKit
import SwiftUI
import UnearthCore

/// A picture on a timeline: square and edge to edge, its selection a ring and a tick.
struct PhotoTile: View {
    let file: IndexedFile?
    let side: CGFloat
    let thumbnailSide: CGFloat
    var selected = false

    var body: some View {
        Group {
            if let file {
                TileThumbnail(file: file, side: thumbnailSide).id(file.id)
            } else {
                Color.hairline.opacity(0.45)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            if let file, selected || file.kind == .video || file.isCloudOnly {
                TileBadges(file: file, selected: selected)
            }
        }
    }
}

/// A folder among the pictures of a big folder: its Finder icon and its name.
struct FolderTile: View {
    let file: IndexedFile
    let side: CGFloat
    var selected = false

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: ThumbnailCache.shared.folderIcon(file.path))
                .resizable()
                .scaledToFit()
                .frame(width: side * 0.5, height: side * 0.5)
            Text(file.name)
                .font(.callout)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(8)
        .frame(width: side, height: side)
        .background(selected ? Color.unearth.opacity(0.12) : Color.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(selected ? Color.unearth : Color.hairline, lineWidth: selected ? 3 : 1)
        }
    }
}

/// What sits on a picture beyond the picture: a video's triangle, the iCloud cloud, the selection.
struct TileBadges: View {
    let file: IndexedFile
    let selected: Bool

    var body: some View {
        ZStack {
            if selected {
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.unearth, lineWidth: 3)
                TileTick(selected: true).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if file.kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .padding(7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            if file.isCloudOnly {
                Image(systemName: "icloud")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(4)
                    .background(.regularMaterial, in: Circle())
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }
}

/// The circle in a picture's corner, ticked when it's selected.
struct TileTick: View {
    let selected: Bool

    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, selected ? Color.unearth : Color.black.opacity(0.25))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .padding(6)
    }
}

/// A thumbnail filling its tile: a quiet gray until it's made, and a tinted stand-in when none can be made.
/// iCloud-only files never get one made, since that would download them.
struct TileThumbnail: View {
    let file: IndexedFile
    let side: CGFloat
    @State private var image: NSImage?
    @State private var failed = false

    init(file: IndexedFile, side: CGFloat) {
        self.file = file
        self.side = side
        _image = State(initialValue: ThumbnailCache.shared.cached(file.path, side: side))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if failed || file.isCloudOnly {
                if KindPlaceholder.covers(file.kind) {
                    KindPlaceholder(kind: file.kind)
                } else {
                    Image(nsImage: ThumbnailCache.shared.icon(for: file)).resizable().scaledToFit().padding(side * 0.18)
                }
            } else {
                Color.hairline.opacity(0.45)
            }
        }
        .task(id: file.path) {
            guard image == nil, !file.isCloudOnly else { return }
            let made = await ThumbnailCache.shared.image(for: file.path, side: side)
            guard !Task.isCancelled else { return }
            image = made
            failed = made == nil
        }
    }
}
