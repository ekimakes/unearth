import CoreServices
import Foundation
import Synchronization

/// Reports folders whose contents changed, from macOS's file system events.
public final class FolderWatcher: Sendable {
    private let paths: [String]
    private let latency: Double
    private let onChange: @Sendable ([String]) -> Void
    private let onOverflow: @Sendable () -> Void
    private let running = Mutex<Running?>(nil)
    private let queue = DispatchQueue(label: "com.ekimakes.unearth.folder-watcher", qos: .utility)

    /// `onChange` gets each batch of changed folders, deduplicated, without trailing slashes.
    /// `onOverflow` runs when macOS dropped events and only a full re-index can catch up.
    public init(
        paths: [String], latency: Double = 1.5, onChange: @escaping @Sendable ([String]) -> Void,
        onOverflow: @escaping @Sendable () -> Void = {}
    ) {
        self.paths = paths
        self.latency = latency
        self.onChange = onChange
        self.onOverflow = onOverflow
    }

    deinit { stop() }

    public func start() {
        running.withLock { current in
            guard current == nil else { return }
            // The stream's callbacks hold the handler until it's released after the stream is gone.
            let handler = Unmanaged.passRetained(Handler(onChange: onChange, onOverflow: onOverflow))
            var context = FSEventStreamContext(version: 0, info: handler.toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
            guard let stream = FSEventStreamCreate(
                nil, Self.callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency, flags) else {
                handler.release()
                return
            }
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            current = Running(stream: stream, handler: handler)
        }
    }

    /// Nothing is reported once this returns.
    public func stop() {
        running.withLock { current in
            guard let run = current else { return }
            run.handler.takeUnretainedValue().isStopped.store(true, ordering: .sequentiallyConsistent)
            FSEventStreamStop(run.stream)
            FSEventStreamInvalidate(run.stream)
            FSEventStreamRelease(run.stream)
            // Callbacks already queued run first on this serial queue, then the handler goes.
            let handler = run.handler
            queue.async { handler.release() }
            current = nil
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        let dropped = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        handler.deliver(paths, overflow: (0..<count).contains { eventFlags[$0] & dropped != 0 })
    }

    private final class Handler: Sendable {
        let onChange: @Sendable ([String]) -> Void
        let onOverflow: @Sendable () -> Void
        let isStopped = Atomic(false)

        init(onChange: @escaping @Sendable ([String]) -> Void, onOverflow: @escaping @Sendable () -> Void) {
            self.onChange = onChange
            self.onOverflow = onOverflow
        }

        func deliver(_ paths: [String], overflow: Bool) {
            guard !isStopped.load(ordering: .sequentiallyConsistent) else { return }
            if overflow { onOverflow() }
            var seen: Set<String> = []
            let folders = paths.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
                .filter { seen.insert($0).inserted }
            if !folders.isEmpty { onChange(folders) }
        }
    }

    /// Only touched while holding the mutex.
    private struct Running: @unchecked Sendable {
        let stream: FSEventStreamRef
        let handler: Unmanaged<Handler>
    }
}
