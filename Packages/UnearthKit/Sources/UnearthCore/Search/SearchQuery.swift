import Foundation

/// One filter the search understood, shown as a chip the user can remove.
public enum QueryChip: Sendable, Hashable {
    case kind(FileKind)
    case fileExtension(String)
    case minBytes(Int64)
    case maxBytes(Int64)
    case added(DateInterval, label: String)
    case source(String)

    public var label: String {
        switch self {
        case .kind(let kind): kind.title
        case .fileExtension(let ext): ext.uppercased()
        case .minBytes(let bytes): "Over \(ByteFormatting.string(bytes))"
        case .maxBytes(let bytes): "Under \(ByteFormatting.string(bytes))"
        case .added(_, let label): label
        case .source(let source): "From \(source)"
        }
    }
}

extension FileKind {
    public var title: String {
        switch self {
        case .image: "Images"
        case .screenshot: "Screenshots"
        case .video: "Videos"
        case .document: "Documents"
        case .audio: "Music & audio"
        case .archive: "Archives"
        case .app: "Apps"
        case .other: "Other files"
        }
    }
}

/// A search as typed: free text plus the filters plain words turned into
/// ("screenshots with invoice", "videos over 1 GB", "pdfs from last week", "from chatgpt").
public struct SearchQuery: Sendable, Equatable {
    public var text = ""
    public var kinds: Set<FileKind> = []
    public var extensions: Set<String> = []
    public var minBytes: Int64?
    public var maxBytes: Int64?
    public var added: DateInterval?
    public var addedLabel: String?
    public var source: String?
    /// A real folder path the files must be inside. Set by the app, never typed, so it isn't a chip.
    public var folder: String?
    /// When the files were made (`IndexedFile.made`): a month or year on a timeline. Set by the app, never typed.
    public var made: DateInterval?
    /// The folder the files are directly in. Set by the app, never typed.
    public var parent: String?
    /// Only files with no download source on record. Set by the app, never typed.
    public var withoutSource = false

    public init() {}

    public var isEmpty: Bool { text.isEmpty && chips.isEmpty }

    public var chips: [QueryChip] {
        var chips = FileKind.allCases.filter(kinds.contains).map(QueryChip.kind)
        chips += extensions.sorted().map(QueryChip.fileExtension)
        if let minBytes { chips.append(.minBytes(minBytes)) }
        if let maxBytes { chips.append(.maxBytes(maxBytes)) }
        if let added { chips.append(.added(added, label: addedLabel ?? "")) }
        if let source { chips.append(.source(source)) }
        return chips
    }

    public func removing(_ chip: QueryChip) -> SearchQuery {
        var query = self
        switch chip {
        case .kind(let kind): query.kinds.remove(kind)
        case .fileExtension(let ext): query.extensions.remove(ext)
        case .minBytes: query.minBytes = nil
        case .maxBytes: query.maxBytes = nil
        case .added: query.added = nil; query.addedLabel = nil
        case .source: query.source = nil
        }
        return query
    }

    // MARK: - Parsing

    /// "Images" and "pictures" include screenshots; "photos" don't.
    private static let kindWords: [String: [FileKind]] = [
        "image": [.image, .screenshot], "images": [.image, .screenshot], "picture": [.image, .screenshot],
        "pictures": [.image, .screenshot], "photo": [.image], "photos": [.image],
        "screenshot": [.screenshot], "screenshots": [.screenshot],
        "video": [.video], "videos": [.video], "movie": [.video], "movies": [.video], "recording": [.video], "recordings": [.video],
        "document": [.document], "documents": [.document], "doc": [.document], "docs": [.document],
        "music": [.audio], "song": [.audio], "songs": [.audio], "audio": [.audio],
        "archive": [.archive], "archives": [.archive], "zip": [.archive], "zips": [.archive],
        "app": [.app], "apps": [.app],
    ]
    private static let spans: [String: (component: Calendar.Component, one: String, many: String)] = [
        "day": (.day, "day", "days"), "days": (.day, "day", "days"),
        "week": (.weekOfYear, "week", "weeks"), "weeks": (.weekOfYear, "week", "weeks"),
        "month": (.month, "month", "months"), "months": (.month, "month", "months"),
        "year": (.year, "year", "years"), "years": (.year, "year", "years"),
    ]
    /// Words that only connect the others ("show me all my photos of dogs").
    private static let fillers: Set<String> = [
        "show", "me", "find", "all", "my", "the", "of", "a", "an", "with", "containing", "that", "have", "has", "in", "and",
        "files", "file", "from", "added",
    ]
    private static let atLeast = ["over", "above", "bigger than", "larger than", "more than", "at least"]
    private static let atMost = ["under", "below", "smaller than", "less than", "at most"]
    private static let units: [String: Double] = ["b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12]

    public static func parse(_ input: String, now: Date, calendar: Calendar = .current) -> SearchQuery {
        var query = SearchQuery()
        var text: [String] = []
        var words: [String] = []
        // Quoted text is always searched as typed.
        for (index, part) in input.split(separator: "\"", omittingEmptySubsequences: false).enumerated() {
            if index % 2 == 1 {
                text += part.split(whereSeparator: \.isWhitespace).map(String.init)
            } else {
                words += part.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
            }
        }

        var index = 0
        while index < words.count {
            let rest = Array(words[index...])
            if let (interval, label, used) = date(rest, now: now, calendar: calendar) {
                query.added = interval
                query.addedLabel = label
                index += used
            } else if let (bytes, isMinimum, used) = size(rest) {
                if isMinimum { query.minBytes = bytes } else { query.maxBytes = bytes }
                index += used
            } else if let (source, used) = source(rest) {
                query.source = source
                index += used
            } else if rest[0] == "pdf" || rest[0] == "pdfs" {
                query.extensions.insert("pdf")
                index += 1
            } else if let kinds = kindWords[rest[0]] {
                query.kinds.formUnion(kinds)
                index += 1
            } else {
                if !fillers.contains(rest[0]) { text.append(rest[0]) }
                index += 1
            }
        }
        query.text = text.joined(separator: " ")
        return query
    }

    /// "today", "yesterday", "this week|month|year" (calendar), and spans that count back from now:
    /// "last week", "the last month", "past 3 months", "last 30 days". Optionally after "from", "added", "in",
    /// "during", "within" or "over".
    private static func date(_ words: [String], now: Date, calendar: Calendar) -> (DateInterval, String, Int)? {
        var used = ["from", "added", "in", "during", "within", "over"].contains(words[0]) ? 1 : 0
        // "the last month", "this past week"
        if words.count > used + 1, ["the", "this"].contains(words[used]), ["last", "past"].contains(words[used + 1]) { used += 1 }
        guard words.count > used else { return nil }
        switch words[used] {
        case "today":
            return calendar.dateInterval(of: .day, for: now).map { ($0, "Today", used + 1) }
        case "yesterday":
            let day = calendar.date(byAdding: .day, value: -1, to: now)!
            return calendar.dateInterval(of: .day, for: day).map { ($0, "Yesterday", used + 1) }
        case "this":
            guard words.count > used + 1, let span = spans[words[used + 1]], span.component != .day else { return nil }
            return calendar.dateInterval(of: span.component, for: now).map { ($0, "This \(span.one)", used + 2) }
        case "last", "past":
            var next = used + 1
            var count = 1
            if next < words.count, let number = Int(words[next]), number > 0, number <= 10_000 {
                count = number
                next += 1
            }
            guard next < words.count, let span = spans[words[next]],
                  let start = calendar.date(byAdding: span.component, value: -count, to: now) else { return nil }
            let label = count == 1 ? "Past \(span.one)" : "Past \(count) \(span.many)"
            return (DateInterval(start: start, end: now), label, next + 1)
        default:
            return nil
        }
    }

    /// "over 1 GB", "under 50mb", "bigger than 1.5 gb". Units are decimal, like Finder's.
    private static func size(_ words: [String]) -> (Int64, Bool, Int)? {
        for (phrases, isMinimum) in [(atLeast, true), (atMost, false)] {
            for phrase in phrases {
                let parts = phrase.split(separator: " ").map(String.init)
                guard words.starts(with: parts) else { continue }
                let rest = words.dropFirst(parts.count)
                guard let number = rest.first else { continue }
                if let bytes = amount(number, unit: nil) { return (bytes, isMinimum, parts.count + 1) }
                if rest.count >= 2, let bytes = amount(number, unit: rest[rest.startIndex + 1]) {
                    return (bytes, isMinimum, parts.count + 2)
                }
            }
        }
        return nil
    }

    private static func amount(_ number: String, unit: String?) -> Int64? {
        let joined = number + (unit ?? "")
        guard let split = joined.firstIndex(where: { $0.isLetter }),
              let value = Double(joined[..<split].replacingOccurrences(of: ",", with: ".")),
              let multiplier = units[String(joined[split...])] else { return nil }
        let bytes = value * multiplier
        guard bytes.isFinite, bytes >= 0 else { return nil }
        return bytes >= Double(Int64.max) ? Int64.max : Int64(bytes)
    }

    /// "from chatgpt", "from google drive", "from example.com". Dates were tried first.
    private static func source(_ words: [String]) -> (String, Int)? {
        guard words.first == "from", words.count >= 2 else { return nil }
        for length in [2, 1] where words.count > length {
            let candidate = words[1...length].joined(separator: " ")
            if let known = DownloadSource.knownNames.first(where: { $0.lowercased() == candidate }) { return (known, length + 1) }
        }
        let word = words[1]
        if word.contains("."), !word.hasPrefix("."), !word.hasSuffix(".") { return (word, 2) }
        return nil
    }
}
