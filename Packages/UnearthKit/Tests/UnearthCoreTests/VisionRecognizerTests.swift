import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import Vision
@testable import UnearthCore

/// Takes no work, to show what depends on Vision's threads.
struct NoThreads: VisionRunning {
    struct Refused: Error {}

    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        throw Refused()
    }
}

struct VisionRecognizerTests {
    /// Draws black text on white into a PNG, the way a screenshot of a document looks.
    static func renderText(_ text: String, to path: String) throws {
        let width = 1_400, height = 300
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 80, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 60, y: 110)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func readsTextFromRenderedImage() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let path = fx.path("invoice.png")
        try Self.renderText("UNEARTH INVOICE 1042", to: path)
        let content = try await VisionRecognizer().recognize(imageAt: path)
        #expect(content.text.contains("INVOICE"))
        #expect(content.text.contains("1042"))
    }

    /// Found by review: text was read as US English only, so other languages were "corrected" or missed.
    @Test func readsTextInOtherLanguages() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let german = fx.path("rechnung.png")
        try Self.renderText("Größe der Straße", to: german)
        let read = try await VisionRecognizer().recognize(imageAt: german).text
        #expect(read.contains("Straße") && read.contains("Größe"), "read: \(read)")
        let japanese = fx.path("seikyusho.png")
        try Self.renderText("請求書 合計金額", to: japanese)
        let japaneseText = try await VisionRecognizer().recognize(imageAt: japanese).text
        #expect(japaneseText.contains("請求書"), "read: \(japaneseText)")
    }

    @Test func labelsAreHumanReadable() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let path = fx.path("invoice.png")
        try Self.renderText("UNEARTH INVOICE 1042", to: path)
        let content = try await VisionRecognizer(minimumLabelConfidence: 0, maxLabels: 5).recognize(imageAt: path)
        #expect(!content.labels.isEmpty)
        #expect(content.labels.count <= 5)
        #expect(content.labels.allSatisfy { !$0.contains("_") })
    }

    @Test func unreadableFileThrows() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let notAnImage = try fx.file("broken.png", bytes: 64)
        await #expect(throws: (any Error).self) { try await VisionRecognizer().recognize(imageAt: notAnImage) }
        await #expect(throws: (any Error).self) { try await VisionRecognizer().recognize(imageAt: fx.path("missing.png")) }
    }

    /// On macOS 15 a text read blocks its thread until other work gets room among Swift's worker threads, so reads on
    /// those threads froze when no worker was left idle. Nothing reaches Vision except on its own threads.
    @Test func visionRunsOnlyOnItsOwnThreads() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let path = fx.path("a.jpg")
        try Self.renderPicture(circleAt: 0, hue: 0.2, to: path)
        let recognizer = VisionRecognizer(threads: NoThreads())
        await #expect(throws: NoThreads.Refused.self) { try await recognizer.recognize(imageAt: path) }
        await #expect(throws: NoThreads.Refused.self) { try await recognizer.recognize(imageAt: path, includingPrint: true) }
        await #expect(throws: NoThreads.Refused.self) { try await recognizer.featurePrint(ofImageAt: path) }
        #expect(await VisionShotScorer(threads: NoThreads()).score(imageAt: path) == nil)
    }

    /// One blocked call for each worker thread: on those threads they would leave no room for anything else.
    @Test func visionThreadsLeaveSwiftWorkerThreadsFree() async throws {
        let workers = ProcessInfo.processInfo.activeProcessorCount
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), answered = DispatchSemaphore(value: 0)
        let calls = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<workers {
                    group.addTask { try? await VisionThreads().run { started.signal(); release.wait() } }
                }
            }
        }
        let free = await withCheckedContinuation { done in
            DispatchQueue.global().async {
                for _ in 0..<workers { _ = started.wait(timeout: .now() + 10) }
                Task.detached { answered.signal() }
                let free = answered.wait(timeout: .now() + 5) == .success
                // Whatever the answer, so a failure here can't hang the tests.
                for _ in 0..<workers { release.signal() }
                done.resume(returning: free)
            }
        }
        await calls.value
        #expect(free)
    }

    /// A gradient with a circle (or two bars when `circleAt` is nil), saved as a JPEG.
    static func renderPicture(circleAt shift: CGFloat?, hue: CGFloat, to path: String) throws {
        let width = 640, height = 480
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors = [CGColor(red: hue, green: 0.4, blue: 1 - hue, alpha: 1), CGColor(red: 1, green: 0.9, blue: 0.2, alpha: 1)]
        let gradient = try #require(CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.2, alpha: 1))
        if let shift {
            context.fillEllipse(in: CGRect(x: 200 + shift, y: 150, width: 200, height: 200))
        } else {
            context.fill(CGRect(x: 50, y: 50, width: 540, height: 80))
            context.fill(CGRect(x: 50, y: 350, width: 540, height: 80))
        }
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func similarRendersHaveCloserPrints() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try Self.renderPicture(circleAt: 0, hue: 0.2, to: fx.path("a.jpg"))
        try Self.renderPicture(circleAt: 12, hue: 0.22, to: fx.path("b.jpg"))
        try Self.renderPicture(circleAt: nil, hue: 0.9, to: fx.path("c.jpg"))
        let recognizer = VisionRecognizer()
        let a = try #require(try await recognizer.recognize(imageAt: fx.path("a.jpg"), includingPrint: true).featurePrint)
        let b = try #require(try await recognizer.featurePrint(ofImageAt: fx.path("b.jpg")))
        let c = try #require(try await recognizer.featurePrint(ofImageAt: fx.path("c.jpg")))
        let comparer = VisionPrintComparer()
        let similar = try #require(comparer.distance(a, b))
        let different = try #require(comparer.distance(a, c))
        #expect(similar < LookAlikeFinder.defaultThreshold)
        #expect(different > LookAlikeFinder.defaultThreshold)
        // The same measure Vision uses.
        let visionA = try await ImageRequestHandler(URL(fileURLWithPath: fx.path("a.jpg"))).perform(GenerateImageFeaturePrintRequest())
        let visionC = try await ImageRequestHandler(URL(fileURLWithPath: fx.path("c.jpg"))).perform(GenerateImageFeaturePrintRequest())
        #expect(abs(Double(different) - (try visionA.distance(to: visionC))) < 0.001)
        #expect(try await recognizer.recognize(imageAt: fx.path("a.jpg")).featurePrint == nil)
        let score = try #require(await VisionShotScorer().score(imageAt: fx.path("a.jpg")))
        #expect((-1...1).contains(score))
    }

    /// Vision only ever reads a plain file on this Mac: never through a link, and never a file whose contents are
    /// only in iCloud (reading one would download it). Links stand in for iCloud-only files, which a test can't make.
    @Test func onlyPlainLocalFilesAreRead() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try Self.renderPicture(circleAt: 0, hue: 0.2, to: fx.path("a.jpg"))
        try fx.symlink("link.jpg", to: fx.path("a.jpg"))
        let recognizer = VisionRecognizer()
        await #expect(throws: (any Error).self) { try await recognizer.recognize(imageAt: fx.path("link.jpg"), includingPrint: true) }
        await #expect(throws: (any Error).self) { try await recognizer.featurePrint(ofImageAt: fx.path("link.jpg")) }
        #expect(await VisionShotScorer().score(imageAt: fx.path("link.jpg")) == nil)
        #expect(try await recognizer.featurePrint(ofImageAt: fx.path("a.jpg")) != nil)
        #expect(LocalFile.isReadable(fx.path("a.jpg")) && !LocalFile.isReadable(fx.path("link.jpg")))
        #expect(!LocalFile.isOnlyInICloud(fx.path("a.jpg")))
    }
}

