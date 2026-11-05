import Foundation
import IOKit.ps

public protocol PowerStateProviding: Sendable {
    var shouldPause: Bool { get }
}

/// Background work waits in Low Power Mode, when the Mac is hot, or on battery below 20%.
public struct SystemPowerState: PowerStateProviding {
    public init() {}

    public var shouldPause: Bool {
        let process = ProcessInfo.processInfo
        if process.isLowPowerModeEnabled { return true }
        if process.thermalState == .serious || process.thermalState == .critical { return true }
        return Self.isOnLowBattery()
    }

    private static func isOnLowBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return false }
            return current * 100 / maximum < 20
        }
    }
}

/// Reads text and objects from the Library's images in the background, newest first, and makes photos'
/// feature prints.
public actor ContentIndexer {
    private let index: FileIndex
    private let recognizer: any ContentRecognizing
    private let printer: (any FeaturePrinting)?
    private let power: any PowerStateProviding
    private let pauseInterval: Duration

    /// With a `printer`, photos also get feature prints for finding look-alikes: new ones while they're read,
    /// ones read before prints existed once everything else is read.
    public init(
        index: FileIndex, recognizer: any ContentRecognizing, printer: (any FeaturePrinting)? = nil,
        power: any PowerStateProviding = SystemPowerState(), pauseInterval: Duration = .seconds(30)
    ) {
        self.index = index
        self.recognizer = recognizer
        self.printer = printer
        self.power = power
        self.pauseInterval = pauseInterval
    }

    /// Runs until nothing is waiting or the task is cancelled, reading up to `concurrency` images at once.
    /// An image that can't be read is marked and skipped; one interrupted by cancelling stays waiting.
    public func run(batchSize: Int = 8, concurrency: Int = 1) async {
        var attempted: Set<Int64> = []
        while !Task.isCancelled {
            if power.shouldPause {
                try? await Task.sleep(for: pauseInterval)
                continue
            }
            var batch = await index.pendingRecognition(limit: batchSize).filter { !attempted.contains($0.id) }
            let printing = batch.isEmpty && printer != nil
            if printing { batch = await index.needingPrints(limit: batchSize).filter { !attempted.contains($0.id) } }
            if batch.isEmpty { return }
            let recognizer = self.recognizer
            let printer = self.printer
            // Only images whose read started count as tried; the rest wait for the next batch.
            let started = await withTaskGroup(of: (IndexedFile, Result<RecognizedContent, any Error>).self) { group in
                var waiting = batch[...]
                var started: [Int64] = []
                func startNext() {
                    guard let file = waiting.popFirst() else { return }
                    started.append(file.id)
                    group.addTask {
                        do {
                            if printing, let printer {
                                let print = try await printer.featurePrint(ofImageAt: file.path)
                                return (file, .success(RecognizedContent(text: "", labels: [], featurePrint: print)))
                            }
                            let wantsPrint = printer != nil && Self.isPhoto(file)
                            return (file, .success(try await recognizer.recognize(imageAt: file.path, includingPrint: wantsPrint)))
                        } catch {
                            return (file, .failure(error))
                        }
                    }
                }
                for _ in 0..<max(1, concurrency) { startNext() }
                while let (file, result) = await group.next() {
                    // Once cancelled (Forget Everything, new folders), nothing more is written.
                    if Task.isCancelled { continue }
                    // A photo Vision can't make a print of gets an empty one, so it isn't tried again.
                    let wantsPrint = printer != nil && Self.isPhoto(file)
                    switch (result, printing) {
                    case (.success(let content), false):
                        try? await index.setContent(for: file, text: content.text, labels: content.labels,
                                                    print: wantsPrint ? content.featurePrint ?? Data() : nil)
                    case (.success(let content), true):
                        try? await index.setPrint(for: file, print: content.featurePrint ?? Data())
                    case (.failure, false):
                        try? await index.markRecognitionFailed(id: file.id)
                    case (.failure, true):
                        try? await index.setPrint(for: file, print: Data())
                    }
                    // Stop starting new reads when cancelled or told to pause; the ones running finish.
                    if !Task.isCancelled, !power.shouldPause { startNext() }
                }
                return started
            }
            attempted.formUnion(started)
        }
    }

    /// Only photos get feature prints: look-alikes are only looked for among them.
    static func isPhoto(_ file: IndexedFile) -> Bool {
        file.kind == .image && FileKinds.photoExtensions.contains(file.fileExtension)
    }
}
