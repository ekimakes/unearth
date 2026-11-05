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

/// Reads images with Apple's Vision framework, on this Mac.
public struct VisionRecognizer: ContentRecognizing, FeaturePrinting {
    private let minimumLabelConfidence: Float
    private let maxLabels: Int

    public init(minimumLabelConfidence: Float = 0.3, maxLabels: Int = 8) {
        self.minimumLabelConfidence = minimumLabelConfidence
        self.maxLabels = maxLabels
    }

    public func recognize(imageAt path: String) async throws -> RecognizedContent {
        try await recognize(imageAt: path, includingPrint: false)
    }

    public func recognize(imageAt path: String, includingPrint: Bool) async throws -> RecognizedContent {
        guard LocalFile.isReadable(path) else { throw RecognitionError.notALocalFile }
        var textRequest = RecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        // Not just US English: Vision finds the language, including Chinese, Japanese and Korean.
        textRequest.automaticallyDetectsLanguage = true
        let handler = ImageRequestHandler(URL(fileURLWithPath: path))
        if includingPrint {
            let (lines, classes, print) = try await handler.perform(
                textRequest, ClassifyImageRequest(), GenerateImageFeaturePrintRequest())
            return content(lines, classes, print: Self.data(of: print))
        }
        let (lines, classes) = try await handler.perform(textRequest, ClassifyImageRequest())
        return content(lines, classes, print: nil)
    }

    public func featurePrint(ofImageAt path: String) async throws -> Data? {
        guard LocalFile.isReadable(path) else { throw RecognitionError.notALocalFile }
        return Self.data(of: try await ImageRequestHandler(URL(fileURLWithPath: path)).perform(GenerateImageFeaturePrintRequest()))
    }

    private func content(_ lines: [RecognizedTextObservation], _ classes: [ClassificationObservation],
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
    static func data(of print: FeaturePrintObservation) -> Data? {
        switch print.elementType {
        case .float:
            return print.data
        case .double:
            let values = print.data.withUnsafeBytes { raw in
                (0..<raw.count / 8).map { Float(raw.loadUnaligned(fromByteOffset: $0 * 8, as: Double.self)) }
            }
            return values.withUnsafeBytes { Data($0) }
        @unknown default:
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
    public init() {}

    public func score(imageAt path: String) async -> Float? {
        guard LocalFile.isReadable(path) else { return nil }
        return try? await ImageRequestHandler(URL(fileURLWithPath: path)).perform(CalculateImageAestheticsScoresRequest()).overallScore
    }
}
