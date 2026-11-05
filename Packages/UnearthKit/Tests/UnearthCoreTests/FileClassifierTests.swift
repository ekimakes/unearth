import Testing
@testable import UnearthCore

struct FileClassifierTests {
    @Test func classifiesByExtensionCaseInsensitively() {
        #expect(FileClassifier.kind(forName: "IMG_0042.HEIC", isScreenshot: false) == .image)
        #expect(FileClassifier.kind(forName: "Trip.MOV", isScreenshot: false) == .video)
        #expect(FileClassifier.kind(forName: "Invoice.PDF", isScreenshot: false) == .document)
        #expect(FileClassifier.kind(forName: "song.flac", isScreenshot: false) == .audio)
        #expect(FileClassifier.kind(forName: "backup.tar.gz", isScreenshot: false) == .archive)
        #expect(FileClassifier.kind(forName: "Installer.dmg", isScreenshot: false) == .archive)
        #expect(FileClassifier.kind(forName: "notes", isScreenshot: false) == .other)
        #expect(FileClassifier.kind(forName: ".zshrc", isScreenshot: false) == .other)
    }

    @Test func screenshotsAreImagesWithFlagOrName() {
        #expect(FileClassifier.kind(forName: "Screenshot 2026-10-13 at 11.37.57.png", isScreenshot: false) == .screenshot)
        #expect(FileClassifier.kind(forName: "Screen Shot 2020-01-02 at 9.15.00 AM.png", isScreenshot: false) == .screenshot)
        #expect(FileClassifier.kind(forName: "CleanShot 2026-11-01 at 10.00.00@2x.png", isScreenshot: false) == .screenshot)
        #expect(FileClassifier.kind(forName: "Bildschirmfoto 2026-11-01 um 10.00.00.png", isScreenshot: true) == .screenshot)
        // A screen recording is still a video.
        #expect(FileClassifier.kind(forName: "Screen Recording 2026-11-01 at 10.00.00.mov", isScreenshot: true) == .video)
        #expect(FileClassifier.kind(forName: "photo.png", isScreenshot: false) == .image)
    }

    @Test func appBundlesAreApps() {
        #expect(FileClassifier.kind(forName: "Xcode.app", isScreenshot: false) == .app)
        #expect(FileClassifier.kind(forName: "Talk.key", isScreenshot: false) == .document)
    }

    @Test func extensionsAreLowercasedWithTarKeptWhole() {
        #expect(FileClassifier.fileExtension("Report.PDF") == "pdf")
        #expect(FileClassifier.fileExtension("site.tar.gz") == "tar.gz")
        #expect(FileClassifier.fileExtension("archive.gz") == "gz")
        #expect(FileClassifier.fileExtension("README") == "")
        #expect(FileClassifier.fileExtension(".gitignore") == "")
    }
}
