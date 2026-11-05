import Darwin
import Foundation
import Testing
@testable import UnearthCore

struct DownloadSourceTests {
    /// Writes the extended attribute the way macOS does: a binary property list.
    static func setMetadata(_ path: String, _ name: String, _ value: Any) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        let status = data.withUnsafeBytes { setxattr(path, "com.apple.metadata:" + name, $0.baseAddress, data.count, 0, 0) }
        #expect(status == 0)
    }

    @Test func readsWhereFromsXattr() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let file = try fx.file("report.pdf", bytes: 100)
        try Self.setMetadata(file, "kMDItemWhereFroms", ["https://files.oaiusercontent.com/file-1/report.pdf", "https://chatgpt.com/"])
        #expect(DownloadSource.whereFroms(atPath: file) == ["https://files.oaiusercontent.com/file-1/report.pdf", "https://chatgpt.com/"])
    }

    @Test func readsScreenCaptureFlag() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let shot = try fx.file("shot.png", bytes: 100)
        let plain = try fx.file("plain.png", bytes: 100)
        try Self.setMetadata(shot, "kMDItemIsScreenCapture", true)
        #expect(DownloadSource.isScreenCapture(atPath: shot))
        #expect(!DownloadSource.isScreenCapture(atPath: plain))
    }

    @Test func noXattrMeansNoSource() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let file = try fx.file("mine.txt", bytes: 10)
        #expect(DownloadSource.whereFroms(atPath: file).isEmpty)
        #expect(DownloadSource.name(for: []) == nil)
        #expect(DownloadSource.name(for: ["data:text/plain;base64,AAAA"]) == nil)
    }

    @Test func namesKnownSources() {
        #expect(DownloadSource.name(for: ["https://files.oaiusercontent.com/x"]) == "ChatGPT")
        #expect(DownloadSource.name(for: ["https://mail.google.com/mail/u/0/"]) == "Gmail")
        #expect(DownloadSource.name(for: ["https://drive.usercontent.google.com/download?id=1"]) == "Google Drive")
        #expect(DownloadSource.name(for: ["https://pbs.twimg.com/media/x.jpg"]) == "X")
        #expect(DownloadSource.name(for: ["blob:https://web.whatsapp.com/1f2e"]) == "WhatsApp")
        #expect(DownloadSource.name(for: ["https://www.google.com/search?q=x"]) == "Google")
    }

    /// macOS records the file's address and the page it came from; the page often names the service.
    @Test func prefersAKnownSourceAmongTheAddresses() {
        #expect(DownloadSource.name(for: ["https://mail-attachment.googleusercontent.com/attachment/u/0/x", "https://mail.google.com/"]) == "Gmail")
    }

    @Test func namesTheAppsPeopleUseMost() {
        let examples = [
            ("https://scontent.cdninstagram.com/v/x.jpg", "Instagram"), ("https://scontent.xx.fbcdn.net/v/x.jpg", "Facebook"),
            ("https://v16.tiktokcdn.com/x.mp4", "TikTok"), ("https://rr3.googlevideo.com/videoplayback", "YouTube"),
            ("https://i.redd.it/x.jpg", "Reddit"), ("https://i.pinimg.com/x.jpg", "Pinterest"),
            ("https://media.licdn.com/x.jpg", "LinkedIn"), ("https://outlook.office.com/mail/", "Outlook"),
            ("https://company-my.sharepoint.com/x", "OneDrive"), ("https://teams.microsoft.com/x", "Microsoft Teams"),
            ("https://us02web.zoom.us/rec/x", "Zoom"), ("https://www.canva.com/design/x", "Canva"),
            ("https://gemini.google.com/app", "Gemini"), ("https://copilot.microsoft.com/x", "Copilot"),
            ("https://www.perplexity.ai/x", "Perplexity"), ("https://images.unsplash.com/x", "Unsplash"),
            ("https://www.microsoft.com/x", "Microsoft"),
        ]
        for (address, name) in examples {
            #expect(DownloadSource.name(for: [address]) == name, "\(address)")
        }
    }

    @Test func everyKnownSourceHasALogo() throws {
        let tests = URL(fileURLWithPath: #filePath)
        let root = tests.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Unearth/Assets.xcassets/Logos")
        var logos: Set<String> = []
        for name in DownloadSource.knownNames {
            let logo = try #require(DownloadSource.logo(for: name), "\(name)")
            #expect(logos.insert(logo).inserted, "\(name) shares a logo")
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(logo).imageset/\(logo).svg").path), "\(name)")
        }
    }

    @Test func aWebsiteHasNoLogo() {
        #expect(DownloadSource.logo(for: "example.com") == nil)
    }

    @Test func fallsBackToDomain() {
        #expect(DownloadSource.name(for: ["https://www.example.co.uk/a"]) == "example.co.uk")
        #expect(DownloadSource.name(for: ["https://cdn.downloads.example.com/a.zip", "https://example.com/get"]) == "example.com")
    }
}
