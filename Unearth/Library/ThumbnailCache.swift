import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers
import UnearthCore

/// Quick Look thumbnails, made once and kept in memory.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 300_000_000
        return cache
    }()
    private var icons: [String: NSImage] = [:]
    /// Thumbnails being made, with how many views are waiting for each.
    private var pending: [String: Job] = [:]

    private struct Job {
        let id = UUID()
        let task: Task<NSImage?, Never>
        var waiting = 0
    }

    private static func key(_ path: String, _ side: CGFloat) -> String { "\(path)#\(Int(side))" }

    func cached(_ path: String, side: CGFloat) -> NSImage? {
        thumbnails.object(forKey: Self.key(path, side) as NSString)
    }

    /// A file's thumbnail. If every view waiting for it goes away, as when scrolling past, it's no longer made.
    func image(for path: String, side: CGFloat) async -> NSImage? {
        let key = Self.key(path, side)
        if let cached = thumbnails.object(forKey: key as NSString) { return cached }
        if pending[key] == nil {
            // The index's iCloud flag can be stale; making a thumbnail of an evicted file would download it.
            guard !LocalFile.isOnlyInICloud(path) else { return nil }
            pending[key] = Job(task: Self.make(path, side: side))
        }
        pending[key]?.waiting += 1
        guard let job = pending[key] else { return nil }
        let image = await withTaskCancellationHandler {
            await job.task.value
        } onCancel: {
            Task { @MainActor in self.stopWaiting(for: key, job: job.id) }
        }
        if let image {
            let pixels = side * side * pow(NSScreen.main?.backingScaleFactor ?? 2, 2)
            thumbnails.setObject(image, forKey: key as NSString, cost: Int(pixels) * 4)
        }
        if pending[key]?.id == job.id { pending[key] = nil }
        return image
    }

    private func stopWaiting(for key: String, job id: UUID) {
        guard pending[key]?.id == id else { return }
        pending[key]?.waiting -= 1
        if pending[key]?.waiting == 0 {
            pending[key]?.task.cancel()
            pending[key] = nil
        }
    }

    private static func make(_ path: String, side: CGFloat) -> Task<NSImage?, Never> {
        // Only ever handed to the generator, which is made to be called from any thread.
        nonisolated(unsafe) let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path), size: CGSize(width: side, height: side),
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        return Task {
            await withTaskCancellationHandler {
                try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            } onCancel: {
                QLThumbnailGenerator.shared.cancel(request)
            }
        }
    }

    /// A folder's Finder icon (special folders have their own).
    func folderIcon(_ path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    /// The Finder icon for a file's type; apps get their own icon.
    func icon(for file: IndexedFile) -> NSImage {
        let key = file.kind == .app ? file.path : file.fileExtension
        if let icon = icons[key] { return icon }
        let icon = file.kind == .app
            ? NSWorkspace.shared.icon(forFile: file.path)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: file.fileExtension) ?? .data)
        icons[key] = icon
        return icon
    }
}

/// A file's thumbnail, with its type's icon until the thumbnail is ready. iCloud-only files keep
/// the icon and get a cloud badge: making a thumbnail would download them.
struct FileThumbnail: View {
    let file: IndexedFile
    var side: CGFloat
    @State private var image: NSImage?

    init(file: IndexedFile, side: CGFloat) {
        self.file = file
        self.side = side
        _image = State(initialValue: ThumbnailCache.shared.cached(file.path, side: side))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(nsImage: ThumbnailCache.shared.icon(for: file)).resizable().scaledToFit().padding(side * 0.14)
            }
        }
        .frame(width: side, height: side)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: max(4, side * 0.06), style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if file.isCloudOnly {
                Image(systemName: "icloud")
                    .font(.system(size: max(9, side * 0.11), weight: .semibold))
                    .padding(4)
                    .background(.regularMaterial, in: Circle())
                    .padding(4)
                    .help("Only in iCloud. Unearth doesn't download it.")
            }
        }
        .task(id: file.path) {
            guard image == nil, !file.isCloudOnly else { return }
            let made = await ThumbnailCache.shared.image(for: file.path, side: side)
            guard !Task.isCancelled else { return }
            image = made
        }
    }
}
