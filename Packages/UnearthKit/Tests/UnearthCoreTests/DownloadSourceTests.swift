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

    @Test func fallsBackToDomain() {
        #expect(DownloadSource.name(for: ["https://www.example.co.uk/a"]) == "example.co.uk")
        #expect(DownloadSource.name(for: ["https://cdn.downloads.example.com/a.zip", "https://example.com/get"]) == "example.com")
    }
}
