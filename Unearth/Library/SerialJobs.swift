import Foundation

/// Runs Library work one job at a time, in the order it was asked for, at utility priority.
/// Index passes, refreshes, drops and erasing never overlap: overlapping passes deleted live files' rows.
@MainActor
final class SerialJobs {
    private struct Job {
        let run: @MainActor () async -> Void
        /// Called instead of `run` when the job is dropped before it starts.
        let drop: @MainActor () -> Void
    }

    private var waiting: [Job] = []
    private var running: Task<Void, Never>?

    func add(_ run: @escaping @MainActor () async -> Void, onDrop drop: @escaping @MainActor () -> Void = {}) {
        waiting.append(Job(run: run, drop: drop))
        if running == nil { startNext() }
    }

    /// Adds `run` and waits until it has run (or was dropped by `cancelAll`).
    func perform(_ run: @escaping @MainActor () async -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            add({ await run(); done.resume() }, onDrop: { done.resume() })
        }
    }

    /// Cancels the running job, drops the waiting ones, and returns once nothing is running.
    func cancelAll() async {
        let dropped = waiting
        waiting.removeAll()
        dropped.forEach { $0.drop() }
        let task = running
        task?.cancel()
        await task?.value
    }

    private func startNext() {
        guard !waiting.isEmpty else {
            running = nil
            return
        }
        let job = waiting.removeFirst()
        running = Task(priority: .utility) { [weak self] in
            await job.run()
            self?.startNext()
        }
    }
}
