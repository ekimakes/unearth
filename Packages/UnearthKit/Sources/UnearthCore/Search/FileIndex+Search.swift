import Foundation

/// Why a file came up in a search.
public enum MatchReason: Sendable, Equatable {
    case name
    case folder
    /// Text read from the image, as a short excerpt around the match.
    case text(String)
    /// The object or scene in the image that matched ("dog").
    case label(String)
    /// Nothing was typed; the filters alone chose it.
    case filters
}

extension MatchReason {
    /// The few words on a result that say why it's there; nil when only filters picked it.
    public var badge: String? {
        switch self {
        case .name: "Name"
        case .folder: "Folder"
        case .text(let excerpt): "Text: “\(excerpt)”"
        case .label(let label): "Looks like: \(label)"
        case .filters: nil
        }
    }
}

public struct SearchHit: Sendable, Identifiable {
    public let file: IndexedFile
    public let reason: MatchReason
    public var id: Int64 { file.id }
}

extension FileIndex {
    /// Typed words match names (weighted highest), objects in images, folders and text in images, by prefix.
    /// With nothing typed, the filters alone pick files, newest first.
    public func search(_ query: SearchQuery, limit: Int) -> [SearchHit] {
        let terms = SearchTerms(query.text)
        let (conditions, values) = Self.filters(query)
        let limitValue = SQLValue.integer(Int64(limit))

        guard !terms.isEmpty else {
            guard !conditions.isEmpty else { return [] }
            let sql = """
                SELECT \(Self.columns) FROM files WHERE \(conditions.joined(separator: " AND "))
                ORDER BY added DESC, files.id DESC LIMIT ?
                """
            let files = (try? statement(sql).rows(values + [limitValue], Self.file)) ?? []
            return files.map { SearchHit(file: $0, reason: .filters) }
        }

        let filter = conditions.map { " AND " + $0 }.joined()
        let sql = """
            SELECT \(Self.columns), files.words, files.folder, files.text, files.labels
            FROM file_text JOIN files ON files.id = file_text.rowid
            WHERE file_text MATCH ?\(filter)
            ORDER BY bm25(file_text, 10.0, 3.0, 1.0, 2.0) LIMIT ?
            """
        let rows = (try? statement(sql).rows([.text(terms.match)] + values + [limitValue]) { row in
            (Self.file(row), row.text(12) ?? "", row.text(13) ?? "", row.text(14) ?? "", row.text(15) ?? "")
        }) ?? []
        return rows.map { file, words, folder, text, labels in
            SearchHit(file: file, reason: terms.reason(words: words, folder: folder, text: text, labels: labels))
        }
    }

    /// A page of files that pass the query's filters, in the given order. Typed text plays no part.
    public func files(matching query: SearchQuery, sort: FileSort, limit: Int, offset: Int) -> [IndexedFile] {
        let (conditions, values) = Self.filters(query)
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = "SELECT \(Self.columns) FROM files \(filter) ORDER BY \(Self.order(sort)) LIMIT ? OFFSET ?"
        return (try? statement(sql).rows(values + [.integer(Int64(limit)), .integer(Int64(offset))], Self.file)) ?? []
    }

    /// The IDs of every file that passes the query's filters, in no particular order.
    public func ids(matching query: SearchQuery) -> [Int64] {
        let (conditions, values) = Self.filters(query)
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return (try? statement("SELECT files.id FROM files \(filter)").rows(values) { $0.int64(0) }) ?? []
    }

    /// These files as the index has them now; ones it no longer has are left out.
    public func files(ids: [Int64]) -> [IndexedFile] {
        guard !ids.isEmpty else { return [] }
        let list = "[" + ids.map(String.init).joined(separator: ",") + "]"
        let sql = "SELECT \(Self.columns) FROM files WHERE files.id IN (SELECT value FROM json_each(?1))"
        return (try? statement(sql).rows([.text(list)], Self.file)) ?? []
    }

    /// SQL conditions for the query's kinds, extensions, sizes, dates, source and folder.
    static func filters(_ query: SearchQuery) -> (conditions: [String], values: [SQLValue]) {
        var conditions: [String] = []
        var values: [SQLValue] = []
        if !query.kinds.isEmpty {
            // A folder or a source is far narrower than a kind: "+" keeps SQLite off the kind's index, which would
            // have it read through every file of that kind to find the few it wants.
            let narrow = query.parent != nil || query.source != nil || query.withoutSource
            conditions.append("\(narrow ? "+" : "")kind IN (\(Array(repeating: "?", count: query.kinds.count).joined(separator: ", ")))")
            values += query.kinds.sorted { $0.rawValue < $1.rawValue }.map { .text($0.rawValue) }
        }
        if !query.extensions.isEmpty {
            conditions.append("ext IN (\(Array(repeating: "?", count: query.extensions.count).joined(separator: ", ")))")
            values += query.extensions.sorted().map(SQLValue.text)
        }
        if let minBytes = query.minBytes { conditions.append("bytes >= ?"); values.append(.integer(minBytes)) }
        if let maxBytes = query.maxBytes { conditions.append("bytes <= ?"); values.append(.integer(maxBytes)) }
        if let added = query.added {
            conditions.append("added >= ? AND added < ?")
            values += [.real(added.start.timeIntervalSince1970), .real(added.end.timeIntervalSince1970)]
        }
        if let source = query.source { conditions.append("source = ?"); values.append(.text(source)) }
        if let folder = query.folder {
            let (low, high) = Self.range(under: folder)
            conditions.append("path > ? AND path < ?")
            values += [.text(low), .text(high)]
        }
        if let made = query.made {
            conditions.append("\(Self.made) >= ? AND \(Self.made) < ?")
            values += [.real(made.start.timeIntervalSince1970), .real(made.end.timeIntervalSince1970)]
        }
        if let parent = query.parent { conditions.append("parent = ?"); values.append(.text(parent)) }
        if query.withoutSource { conditions.append("source IS NULL") }
        return (conditions, values)
    }
}

/// The typed words, each with its own forms (matched anywhere) and related words (matched only against
/// what Vision saw in images). Only letters and digits survive, so nothing typed is ever read as FTS syntax.
struct SearchTerms {
    private struct Term {
        let forms: [String]
        let related: [String]
    }

    private let terms: [Term]

    init(_ text: String) {
        terms = Self.words(in: text).map { word in
            Term(forms: Synonyms.forms(of: word).map(Self.fold), related: Synonyms.related(to: word).map(Self.fold))
        }
    }

    var isEmpty: Bool { terms.isEmpty }

    /// Every typed word as quoted prefixes; its related words count only in the labels column.
    var match: String {
        terms.map { term in
            var alternatives = term.forms.map { "\"\($0)\"*" }
            if !term.related.isEmpty {
                alternatives.append("{labels} : (" + term.related.map { "\"\($0)\"*" }.joined(separator: " OR ") + ")")
            }
            return "(" + alternatives.joined(separator: " OR ") + ")"
        }.joined(separator: " AND ")
    }

    /// Checked in order: name, objects, text, folder.
    func reason(words: String, folder: String, text: String, labels: String) -> MatchReason {
        if matches(words) { return .name }
        if let label = labels.components(separatedBy: ", ").first(where: { matches($0, withRelated: true) }) { return .label(label) }
        if matches(text) { return .text(snippet(text)) }
        if matches(folder) { return .folder }
        return .name
    }

    private func matches(_ value: String, withRelated: Bool = false) -> Bool {
        let folded = Self.fold(value)
        let valueWords = Self.words(in: folded)
        return terms.contains { term in
            (term.forms + (withRelated ? term.related : [])).contains { alternative in
                alternative.contains(" ") ? folded.contains(alternative) : valueWords.contains { $0.hasPrefix(alternative) }
            }
        }
    }

    /// About 60 characters of the text, on one line, starting at the word that matched, so even a short
    /// badge shows the match.
    private func snippet(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard let found = terms.flatMap(\.forms).lazy.compactMap({ flat.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }).first
        else { return String(flat.prefix(60)) }
        var start = found.lowerBound
        while start > flat.startIndex, !flat[flat.index(before: start)].isWhitespace { start = flat.index(before: start) }
        let rest = flat[start...]
        let piece = rest.prefix(60)
        return (start > flat.startIndex ? "…" : "") + piece.trimmingCharacters(in: .whitespaces) + (piece.count < rest.count ? "…" : "")
    }

    /// Lowercase without accents, the way the full-text index folds words. Not Foundation's case folding,
    /// which turns "ß" into "ss" where the index keeps "ß".
    static func fold(_ value: String) -> String {
        value.folding(options: .diacriticInsensitive, locale: nil).lowercased()
    }

    /// Runs of letters and digits, folded the way the full-text index folds them.
    static func words(in text: String) -> [String] {
        fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
