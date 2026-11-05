import Foundation
import Testing
@testable import UnearthCore

struct SearchTests {
    static func record(_ path: String, kind: FileKind = .document, added: Double = 1_000, source: String? = nil) -> IndexedFileRecord {
        FileIndexTests.record(path, kind: kind, added: added, source: source)
    }

    /// An index with a few files, two of them images whose contents were read.
    static func library() async throws -> FileIndex {
        let index = try FileIndex.inMemory()
        try await index.upsert([
            record("/u/Documents/Invoice_2025.pdf", added: 10),
            record("/u/Desktop/Screenshot 2026-10-13 at 11.37.57.png", kind: .screenshot, added: 30),
            record("/u/Pictures/IMG_0042.heic", kind: .image, added: 20),
            record("/u/Documents/Taxes/2025.pdf", added: 5),
            record("/u/Downloads/x-ray.png", kind: .image, added: 1, source: "ChatGPT"),
            record("/u/Documents/Café notes.txt", added: 2),
            record("/u/Documents/foo.txt", added: 3),
            record("/u/Documents/Not ready.txt", added: 4),
        ], generation: await index.beginPass())
        let files = await index.files(kind: nil, source: nil, parent: nil, sort: .name, limit: 100, offset: 0)
        let shot = try #require(files.first { $0.name.hasPrefix("Screenshot") })
        try await index.setContent(id: shot.id, text: "Order confirmation\nUNEARTH INVOICE 1042\nTotal 99 EUR", labels: ["document"])
        let photo = try #require(files.first { $0.name == "IMG_0042.heic" })
        try await index.setContent(id: photo.id, text: "", labels: ["dog", "golden retriever", "grass"])
        return index
    }

    static func search(_ index: FileIndex, _ text: String, kinds: Set<FileKind> = []) async -> [SearchHit] {
        var query = SearchQuery()
        query.text = text
        query.kinds = kinds
        return await index.search(query, limit: 50)
    }

    @Test func findsByName() async throws {
        let hits = await Self.search(try await Self.library(), "invoice_2025")
        #expect(hits.first?.file.name == "Invoice_2025.pdf")
        #expect(hits.first?.reason == .name)
    }

    @Test func findsByTextInsideImageWithSnippet() async throws {
        let hits = await Self.search(try await Self.library(), "1042")
        let hit = try #require(hits.first)
        #expect(hit.file.kind == .screenshot)
        guard case .text(let snippet) = hit.reason else { Issue.record("expected a text match, got \(hit.reason)"); return }
        // The excerpt starts at the match, so even a short badge shows it.
        #expect(snippet == "…1042 Total 99 EUR")
        guard case .text(let fromStart) = await Self.search(try await Self.library(), "order").first?.reason else { return }
        #expect(fromStart == "Order confirmation UNEARTH INVOICE 1042 Total 99 EUR")
    }

    @Test func findsByLabelAndSynonym() async throws {
        let index = try await Self.library()
        for word in ["dog", "dogs", "puppy", "retriever"] {
            let hit = await Self.search(index, word).first
            #expect(hit?.file.name == "IMG_0042.heic", "searching \(word)")
            if case .label = hit?.reason {} else { Issue.record("searching \(word) gave \(String(describing: hit?.reason))") }
        }
        #expect(await Self.search(index, "puppy").first?.reason == .label("dog"))
    }

    @Test func nameRanksAboveText() async throws {
        let hits = await Self.search(try await Self.library(), "invoice")
        #expect(hits.map(\.file.name).prefix(2) == ["Invoice_2025.pdf", "Screenshot 2026-10-13 at 11.37.57.png"])
        #expect(hits.map(\.reason).first == .name)
    }

    @Test func folderMatchesSayTheFolder() async throws {
        let hits = await Self.search(try await Self.library(), "taxes")
        #expect(hits.map(\.file.name) == ["2025.pdf"])
        #expect(hits.first?.reason == .folder)
    }

    @Test func filtersApplyWithText() async throws {
        let hits = await Self.search(try await Self.library(), "invoice", kinds: [.screenshot])
        #expect(hits.map(\.file.kind) == [.screenshot])
        var query = SearchQuery()
        query.source = "ChatGPT"
        query.text = "ray"
        #expect(await (try await Self.library()).search(query, limit: 10).map(\.file.name) == ["x-ray.png"])
    }

    @Test func filtersOnlyWhenTextEmpty() async throws {
        var query = SearchQuery()
        query.kinds = [.image, .screenshot]
        let hits = await (try await Self.library()).search(query, limit: 10)
        #expect(hits.map(\.file.name) == ["Screenshot 2026-10-13 at 11.37.57.png", "IMG_0042.heic", "x-ray.png"])
        #expect(hits.allSatisfy { $0.reason == .filters })
        var sized = SearchQuery()
        sized.minBytes = 1_000
        #expect(await (try await Self.library()).search(sized, limit: 10).isEmpty)
    }

    /// Search input is never FTS syntax: quotes, operators, emoji and accents just search.
    @Test func hostileQueriesAreSanitized() async throws {
        let index = try await Self.library()
        #expect(await Self.search(index, "\"foo").map(\.file.name) == ["foo.txt"])
        #expect(await Self.search(index, "-x").map(\.file.name) == ["x-ray.png"])
        #expect(await Self.search(index, "NOT ready").map(\.file.name) == ["Not ready.txt"])
        #expect(await Self.search(index, "ray OR").isEmpty)
        #expect(await Self.search(index, "cafe").map(\.file.name) == ["Café notes.txt"])
        #expect(await Self.search(index, "café").map(\.file.name) == ["Café notes.txt"])
        for input in ["a*b", ":", "(", "🗂", "^", "+", "NEAR(", "\"\"", "*"] {
            _ = await Self.search(index, input)
        }
        #expect(await Self.search(index, "🗂").isEmpty)
    }

    /// Browse screens page through filtered files in the order the user picked; typed text plays no part.
    @Test func filesMatchingFiltersAreSortedAndPaged() async throws {
        let index = try FileIndex.inMemory()
        try await index.upsert([
            FileIndexTests.record("/u/a.jpg", kind: .image, bytes: 300, added: 1),
            FileIndexTests.record("/u/b.png", kind: .screenshot, bytes: 900, added: 2),
            FileIndexTests.record("/u/c.jpg", kind: .image, bytes: 600, added: 3),
            FileIndexTests.record("/u/d.jpg", kind: .image, bytes: 10, added: 4),
            FileIndexTests.record("/u/e.pdf", bytes: 5_000, added: 5, source: "Gmail"),
        ], generation: await index.beginPass())
        var filter = SearchQuery()
        filter.kinds = [.image, .screenshot]
        filter.minBytes = 100
        filter.text = "ignored"
        let first = await index.files(matching: filter, sort: .size, limit: 2, offset: 0)
        let second = await index.files(matching: filter, sort: .size, limit: 2, offset: 2)
        #expect(first.map(\.name) == ["b.png", "c.jpg"])
        #expect(second.map(\.name) == ["a.jpg"])
        filter.added = DateInterval(start: Date(timeIntervalSince1970: 2), end: Date(timeIntervalSince1970: 4))
        #expect(await index.files(matching: filter, sort: .added, limit: 10, offset: 0).map(\.name) == ["c.jpg", "b.png"])
        var everything = SearchQuery()
        everything.source = "Gmail"
        #expect(await index.files(matching: everything, sort: .name, limit: 10, offset: 0).map(\.name) == ["e.pdf"])
        #expect(await index.files(matching: SearchQuery(), sort: .name, limit: 10, offset: 0).count == 5)
    }

    @Test func whyBadgesReadNaturally() {
        #expect(MatchReason.name.badge == "Name")
        #expect(MatchReason.folder.badge == "Folder")
        #expect(MatchReason.text("…INVOICE 1042").badge == "Text: “…INVOICE 1042”")
        #expect(MatchReason.label("golden retriever").badge == "Looks like: golden retriever")
        #expect(MatchReason.filters.badge == nil)
    }

    @Test func longTextIsCutAroundTheMatch() async throws {
        let index = try FileIndex.inMemory()
        try await index.upsert([FileIndexTests.record("/u/scan.png", kind: .image)], generation: await index.beginPass())
        let scan = try #require(await index.recent(limit: 1).first)
        let words = (1...40).map { "word\($0)" }.joined(separator: " ")
        try await index.setContent(id: scan.id, text: words + " MATCHED " + words, labels: [])
        guard case .text(let snippet) = await Self.search(index, "matched").first?.reason else {
            Issue.record("expected a text match"); return
        }
        #expect(snippet.hasPrefix("…MATCHED word1"))
        #expect(snippet.hasSuffix("…"))
        #expect(snippet.count <= 64)
    }

    /// "puppy" finds a photo of a dog, but "invoice" doesn't find a file named "Receipt": synonyms only
    /// widen what Vision saw in images; names, folders and text match the words typed.
    @Test func synonymsOnlyWidenObjectSearches() async throws {
        let index = try FileIndex.inMemory()
        try await index.upsert([
            FileIndexTests.record("/u/Receipt scan.jpg", kind: .image, added: 1),
            FileIndexTests.record("/u/IMG_7.jpg", kind: .image, added: 2),
            FileIndexTests.record("/u/Invoice.pdf", added: 3),
        ], generation: await index.beginPass())
        let files = await index.recent(limit: 10)
        try await index.setContent(id: try #require(files.first { $0.name == "Receipt scan.jpg" }).id, text: "RECEIPT TOTAL 7.00",
                                   labels: ["document"])
        try await index.setContent(id: try #require(files.first { $0.name == "IMG_7.jpg" }).id, text: "", labels: ["receipt"])
        let hits = await Self.search(index, "invoice")
        #expect(hits.map(\.file.name) == ["Invoice.pdf", "IMG_7.jpg"])
        #expect(hits.last?.reason == .label("receipt"))
        #expect(await Self.search(index, "receipts").map(\.file.name).sorted() == ["IMG_7.jpg", "Receipt scan.jpg"])
    }

    /// Found by review: "ß" folded to "ss" on the Swift side but not in the full-text index.
    @Test func findsWordsWithSharpS() async throws {
        let index = try FileIndex.inMemory()
        try await index.upsert([FileIndexTests.record("/u/Straße.pdf"), FileIndexTests.record("/u/Größe Tabelle.xlsx")],
                               generation: await index.beginPass())
        #expect(await Self.search(index, "Straße").map(\.file.name) == ["Straße.pdf"])
        #expect(await Self.search(index, "straße").map(\.file.name) == ["Straße.pdf"])
        #expect(await Self.search(index, "größe").map(\.file.name) == ["Größe Tabelle.xlsx"])
    }

    @Test func synonymsGoBothWaysAndHandlePlurals() {
        #expect(Synonyms.expand("puppy").contains("dog"))
        #expect(Synonyms.expand("dog").contains("puppy"))
        #expect(Synonyms.expand("kittens").contains("cat"))
        #expect(Synonyms.expand("receipts").contains("receipt"))
        #expect(!Synonyms.expand("invoice").contains("invoice"))
    }

    @Test func folderFilterLimitsToAFolder() async throws {
        let index = try FileIndex.inMemory()
        try await index.upsert([
            Self.record("/u/Downloads/report a.pdf"),
            Self.record("/u/Downloads/sub/report b.pdf"),
            Self.record("/u/Downloads 2/report c.pdf"),
            Self.record("/u/Downloads2/report d.pdf"),
            Self.record("/u/Documents/report e.pdf"),
        ], generation: await index.beginPass())
        var query = SearchQuery()
        query.folder = "/u/Downloads"
        let listed = await index.files(matching: query, sort: .name, limit: 10, offset: 0)
        #expect(listed.map(\.name) == ["report a.pdf", "report b.pdf"])
        query.text = "report"
        let found = await index.search(query, limit: 10)
        #expect(Set(found.map(\.file.name)) == ["report a.pdf", "report b.pdf"])
        #expect(query.chips.isEmpty)
    }
}
