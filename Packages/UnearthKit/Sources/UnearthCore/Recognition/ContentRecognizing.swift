import Foundation
import Vision

/// What's in an image: the text it shows, the objects and scenes in it, and for photos a feature print
/// that tells how alike two photos look.
public struct RecognizedContent: Sendable, Equatable {
    public let text: String
    public let labels: [String]
    public let featurePrint: Data?

    public init(text: String, labels: [String], featurePrint: Data? = nil) {
        self.text = text
        self.labels = labels
        self.featurePrint = featurePrint
    }
}

public protocol ContentRecognizing: Sendable {
    func recognize(imageAt path: String) async throws -> RecognizedContent
    /// The same, also making the photo's feature print in the same pass when `includingPrint`.
    func recognize(imageAt path: String, includingPrint: Bool) async throws -> RecognizedContent
}

extension ContentRecognizing {
    public func recognize(imageAt path: String, includingPrint: Bool) async throws -> RecognizedContent {
        try await recognize(imageAt: path)
    }
}

/// Makes the feature print of a photo that was read before prints existed.
public protocol FeaturePrinting: Sendable {
    func featurePrint(ofImageAt path: String) async throws -> Data?
}

/// Where Vision's calls run. They block the thread they're on.
public protocol VisionRunning: Sendable {
    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T
}

/// Threads for Vision alone. On macOS 15 a text read blocks its thread until other work gets room among Swift's worker
/// threads, so reads on those threads froze when no worker was left idle. Vision's async calls start their work on
/// those threads whatever the caller prefers, so its blocking calls run here instead.
public struct VisionThreads: VisionRunning {
    private static let queue = DispatchQueue(label: "com.ekimakes.unearth.vision", qos: .utility, attributes: .concurrent, autoreleaseFrequency: .workItem)

    public init() {}

    public func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { finished in
            Self.queue.async { finished.resume(with: Result(catching: work)) }
        }
    }
}

/// Reads images with Apple's Vision framework, on this Mac.
public struct VisionRecognizer: ContentRecognizing, FeaturePrinting {
    private let minimumLabelConfidence: Float
    private let maxLabels: Int
    private let threads: any VisionRunning

    public init(minimumLabelConfidence: Float = 0.3, maxLabels: Int = 8, threads: any VisionRunning = VisionThreads()) {
        self.minimumLabelConfidence = minimumLabelConfidence
        self.maxLabels = maxLabels
        self.threads = threads
    }

    public func recognize(imageAt path: String) async throws -> RecognizedContent {
        try await recognize(imageAt: path, includingPrint: false)
    }

    public func recognize(imageAt path: String, includingPrint: Bool) async throws -> RecognizedContent {
        guard LocalFile.isReadable(path) else { throw RecognitionError.notALocalFile }
        return try await threads.run { [self] in
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            // Not just US English: Vision finds the language, including Chinese, Japanese and Korean.
            textRequest.automaticallyDetectsLanguage = true
            let classifyRequest = VNClassifyImageRequest()
            let printRequest = VNGenerateImageFeaturePrintRequest()
            let requests: [VNRequest] = includingPrint ? [textRequest, classifyRequest, printRequest] : [textRequest, classifyRequest]
            try VNImageRequestHandler(url: URL(fileURLWithPath: path)).perform(requests)
            return content(textRequest.results ?? [], classifyRequest.results ?? [],
                           print: printRequest.results?.first.flatMap(Self.data(of:)))
        }
    }

    public func featurePrint(ofImageAt path: String) async throws -> Data? {
        guard LocalFile.isReadable(path) else { throw RecognitionError.notALocalFile }
        return try await threads.run {
            let request = VNGenerateImageFeaturePrintRequest()
            try VNImageRequestHandler(url: URL(fileURLWithPath: path)).perform([request])
            return request.results?.first.flatMap(Self.data(of:))
        }
    }

    private func content(_ lines: [VNRecognizedTextObservation], _ classes: [VNClassificationObservation],
                         print: Data?) -> RecognizedContent {
        let text = lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        // Vision names things like "golden_retriever"; people search for "golden retriever".
        let labels = classes.filter { $0.confidence >= minimumLabelConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxLabels)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        return RecognizedContent(text: text, labels: Array(labels), featurePrint: print)
    }

    /// The print's numbers as 32-bit floats, the form VisionPrintComparer reads.
    static func data(of print: VNFeaturePrintObservation) -> Data? {
        switch print.elementType {
        case .float:
            return print.data
        case .double:
            let values = print.data.withUnsafeBytes { raw in
                (0..<raw.count / 8).map { Float(raw.loadUnaligned(fromByteOffset: $0 * 8, as: Double.self)) }
            }
            return values.withUnsafeBytes { Data($0) }
        default:
            return nil
        }
    }
}

/// How unlike two photos look, from their feature prints.
public protocol FeaturePrintComparing: Sendable {
    func distance(_ a: Data, _ b: Data) -> Float?
}

/// The squared distance between two prints, the measure Vision's own `distance(to:)` gives.
public struct VisionPrintComparer: FeaturePrintComparing {
    public init() {}

    public func distance(_ a: Data, _ b: Data) -> Float? {
        guard a.count == b.count, !a.isEmpty, a.count % 4 == 0 else { return nil }
        return a.withUnsafeBytes { x in
            b.withUnsafeBytes { y in
                var sum: Float = 0
                for offset in stride(from: 0, to: x.count, by: 4) {
                    let difference = x.loadUnaligned(fromByteOffset: offset, as: Float.self)
                        - y.loadUnaligned(fromByteOffset: offset, as: Float.self)
                    sum += difference * difference
                }
                return sum
            }
        }
    }
}

/// How good a shot a photo is.
public protocol ShotScoring: Sendable {
    func score(imageAt path: String) async -> Float?
}

/// Vision's aesthetics score, from -1 to 1.
public struct VisionShotScorer: ShotScoring {
    private let threads: any VisionRunning

    public init(threads: any VisionRunning = VisionThreads()) {
        self.threads = threads
    }

    public func score(imageAt path: String) async -> Float? {
        guard LocalFile.isReadable(path) else { return nil }
        return try? await threads.run {
            let request = VNCalculateImageAestheticsScoresRequest()
            try VNImageRequestHandler(url: URL(fileURLWithPath: path)).perform([request])
            return request.results?.first?.overallScore
        }
    }
}
