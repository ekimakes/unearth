import Foundation

/// How a screen's files are split into sections.
public enum FileGrouping: String, Sendable, CaseIterable {
    /// By the month each file was made, newest first, with a big month split into its days.
    case date
    /// By the folder each file is in, the folder with the most files first.
    case folder
    /// By where each file was downloaded from, the source with the most files first and files with none last.
    case source
    /// One long run of files.
    case none
}

/// A run of files shown together: a month, a day, a folder or a download source.
public struct FileSection: Sendable, Hashable, Identifiable {
    public enum Key: Sendable, Hashable {
        case month(year: Int, month: Int)
        /// A day of a month too big to show as one run.
        case day(year: Int, month: Int, day: Int)
        case folder(String)
        /// nil: files with no download source on record.
        case source(String?)
        /// The folders inside a folder being listed, above its files.
        case subfolders

        /// The year of a month or a day.
        public var year: Int? {
            switch self {
            case .month(let year, _), .day(let year, _, _): year
            default: nil
            }
        }

        /// The month a month or a day is in.
        public var containingMonth: Key? {
            switch self {
            case .month: self
            case .day(let year, let month, _): .month(year: year, month: month)
            default: nil
            }
        }
    }

    /// Past this many files, a month is split into its days.
    public static let dayThreshold = 1_000

    public let key: Key
    public let count: Int
    public let bytes: Int64
    public var id: Key { key }

    public init(key: Key, count: Int, bytes: Int64) {
        self.key = key
        self.count = count
        self.bytes = bytes
    }

    /// `query` narrowed to this section's files.
    public func query(within query: SearchQuery, calendar: Calendar) -> SearchQuery {
        var narrowed = query
        switch key {
        case .month(let year, let month):
            narrowed.made = Self.narrow(query.made, to: Self.interval(of: .month, year: year, month: month, day: 1, calendar: calendar))
        case .day(let year, let month, let day):
            narrowed.made = Self.narrow(query.made, to: Self.interval(of: .day, year: year, month: month, day: day, calendar: calendar))
        case .folder(let folder):
            narrowed.parent = folder
        case .source(let source):
            if let source { narrowed.source = source } else { narrowed.withoutSource = true }
        case .subfolders:
            break
        }
        return narrowed
    }

    /// Months gathered into their years, newest first, with a split month's days back in one piece. Sections that
    /// aren't dates are left out.
    public static func years(_ sections: [FileSection]) -> [FileYear] {
        var months: [FileSection] = []
        for section in sections {
            guard let month = section.key.containingMonth else { continue }
            if let last = months.last, last.key == month {
                months[months.count - 1] = FileSection(key: month, count: last.count + section.count, bytes: last.bytes + section.bytes)
            } else {
                months.append(FileSection(key: month, count: section.count, bytes: section.bytes))
            }
        }
        var years: [FileYear] = []
        var run: [FileSection] = []
        for month in months {
            if let first = run.first, first.key.year != month.key.year {
                years.append(FileYear(year: first.key.year ?? 0, months: run))
                run = []
            }
            run.append(month)
        }
        if let first = run.first { years.append(FileYear(year: first.key.year ?? 0, months: run)) }
        return years
    }

    /// Where each year's newest month is among `sections`, for marking the years on a timeline.
    public static func yearStarts(_ sections: [FileSection]) -> [(year: Int, section: Int)] {
        var starts: [(year: Int, section: Int)] = []
        for (index, section) in sections.enumerated() {
            if let year = section.key.year, starts.last?.year != year { starts.append((year, index)) }
        }
        return starts
    }

    /// Which grouping tells a screen's files apart: by date, unless most of them came in one burst and their
    /// folders split them far better than the months do, as with exports, frames and other batches.
    public static func fittingGrouping(months sections: [FileSection], folders: [FileSection]) -> FileGrouping {
        let months = years(sections).flatMap(\.months)
        let total = months.reduce(0) { $0 + $1.count }
        guard total >= 200, let biggestMonth = months.map(\.count).max(), let biggestFolder = folders.map(\.count).max() else {
            return .date
        }
        return biggestMonth * 3 > total && biggestFolder * 2 < biggestMonth ? .folder : .date
    }

    /// What to name along a rail, with each section's height on it in `positions`: every year that fits, then in
    /// the gaps the months, then the days, never closer together than `spacing`. A library that's nearly all one
    /// year still gets a rail worth reading.
    public static func railMarks(_ sections: [FileSection], positions: [Double], spacing: Double) -> [RailMark] {
        var marks: [RailMark] = []
        func place(_ label: RailMark.Label, at section: Int) {
            guard positions.indices.contains(section) else { return }
            let y = positions[section]
            if marks.allSatisfy({ abs($0.y - y) >= spacing }) { marks.append(RailMark(label: label, y: y)) }
        }
        for (year, section) in yearStarts(sections) { place(.year(year), at: section) }
        var month: Key?
        for (index, section) in sections.enumerated() {
            guard let containing = section.key.containingMonth, containing != month else { continue }
            month = containing
            if case .month(let year, let number) = containing { place(.month(year: year, month: number), at: index) }
        }
        for (index, section) in sections.enumerated() {
            if case .day(let year, let month, let day) = section.key { place(.day(year: year, month: month, day: day), at: index) }
        }
        return marks.sorted { $0.y < $1.y }
    }

    /// Files already in memory, like a folder listing, split the way the index splits a query; each section's
    /// files newest first.
    public static func group(_ files: [IndexedFile], by grouping: FileGrouping, calendar: Calendar,
                             splittingMonthsOver limit: Int = dayThreshold) -> [(section: FileSection, files: [IndexedFile])] {
        let newestFirst = files.sorted { $0.made != $1.made ? $0.made > $1.made : $0.id > $1.id }
        func section(_ key: Key, _ files: [IndexedFile]) -> (section: FileSection, files: [IndexedFile]) {
            (FileSection(key: key, count: files.count, bytes: files.reduce(0) { $0 + $1.bytes }), files)
        }
        switch grouping {
        case .none:
            return []
        case .date:
            return dateRuns(newestFirst, date: \.made, calendar: calendar, limit: limit).map { section($0.key, $0.items) }
        case .folder:
            return Dictionary(grouping: newestFirst, by: \.parent)
                .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
                .map { section(.folder($0.key), $0.value) }
        case .source:
            return Dictionary(grouping: newestFirst, by: \.source)
                .sorted { left, right in
                    if (left.key == nil) != (right.key == nil) { return right.key == nil }
                    return left.value.count != right.value.count ? left.value.count > right.value.count
                                                                  : (left.key ?? "") < (right.key ?? "")
                }
                .map { section(.source($0.key), $0.value) }
        }
    }

    /// Dates and sizes, newest first, counted by month, or by day in a month of more than `limit`.
    static func dated(_ dated: [(date: Date, bytes: Int64)], calendar: Calendar, limit: Int) -> [FileSection] {
        dateRuns(dated, date: \.date, calendar: calendar, limit: limit).map { run in
            FileSection(key: run.key, count: run.items.count, bytes: run.items.reduce(0) { $0 + $1.bytes })
        }
    }

    /// `calendar`'s time zone in the Gregorian calendar. Months are told apart by year and month number, which only
    /// it keeps unique: Japanese years repeat across eras and Chinese leap months repeat their number.
    public static func gregorian(like calendar: Calendar) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        gregorian.locale = calendar.locale
        return gregorian
    }

    /// Items already newest first, split by month, and a month of more than `limit` by day.
    static func dateRuns<Item>(_ items: [Item], date: (Item) -> Date, calendar: Calendar,
                               limit: Int) -> [(key: Key, items: [Item])] {
        let calendar = gregorian(like: calendar)
        return runs(items, of: .month, date: date, calendar: calendar).flatMap { run in
            run.items.count > limit ? runs(run.items, of: .day, date: date, calendar: calendar) : [run]
        }
    }

    /// Items already newest first, split where the month or the day changes. They follow the calendar's time zone
    /// and its daylight saving time, and the calendar is asked only once per run, however many items there are.
    private static func runs<Item>(_ items: [Item], of unit: Calendar.Component, date: (Item) -> Date,
                                   calendar: Calendar) -> [(key: Key, items: [Item])] {
        var runs: [(key: Key, items: [Item])] = []
        var current: DateInterval?
        for item in items {
            let day = date(item)
            if let current, current.start <= day, day < current.end {
                runs[runs.count - 1].items.append(item)
                continue
            }
            guard let interval = calendar.dateInterval(of: unit, for: day) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: interval.start)
            guard let year = parts.year, let month = parts.month, let number = parts.day else { continue }
            current = interval
            runs.append((unit == .day ? .day(year: year, month: month, day: number) : .month(year: year, month: month), [item]))
        }
        return runs
    }

    static func interval(of unit: Calendar.Component, year: Int, month: Int, day: Int, calendar: Calendar) -> DateInterval? {
        let calendar = gregorian(like: calendar)
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
            .flatMap { calendar.dateInterval(of: unit, for: $0) }
    }

    /// `interval` within what the query already asks for; nil only when the interval itself is unknown.
    static func narrow(_ existing: DateInterval?, to interval: DateInterval?) -> DateInterval? {
        guard let interval else { return existing }
        guard let existing else { return interval }
        return existing.intersection(with: interval) ?? DateInterval(start: interval.start, duration: 0)
    }
}

/// A name along a timeline's rail.
public struct RailMark: Sendable, Hashable {
    public enum Label: Sendable, Hashable {
        case year(Int)
        case month(year: Int, month: Int)
        case day(year: Int, month: Int, day: Int)
    }

    public let label: Label
    /// How far down the rail it goes.
    public let y: Double
}

/// A year on a timeline, with its months.
public struct FileYear: Sendable, Hashable, Identifiable {
    public let year: Int
    /// Newest first.
    public let months: [FileSection]
    public let count: Int
    public let bytes: Int64
    public var id: Int { year }

    public init(year: Int, months: [FileSection]) {
        self.year = year
        self.months = months
        count = months.reduce(0) { $0 + $1.count }
        bytes = months.reduce(0) { $0 + $1.bytes }
    }

    /// `query` narrowed to this year's files.
    public func query(within query: SearchQuery, calendar: Calendar) -> SearchQuery {
        var narrowed = query
        let calendar = FileSection.gregorian(like: calendar)
        let interval = calendar.date(from: DateComponents(year: year, month: 1, day: 1))
            .flatMap { calendar.dateInterval(of: .year, for: $0) }
        narrowed.made = FileSection.narrow(query.made, to: interval)
        return narrowed
    }
}

extension FileIndex {
    /// How to split the query's files: see `FileSection.fittingGrouping`.
    public func fittingGrouping(matching query: SearchQuery, calendar: Calendar) -> FileGrouping {
        FileSection.fittingGrouping(months: sections(matching: query, by: .date, calendar: calendar),
                                    folders: sections(matching: query, by: .folder, calendar: calendar))
    }

    /// The query's files split into sections: one per month or day, folder or source among them.
    public func sections(matching query: SearchQuery, by grouping: FileGrouping, calendar: Calendar,
                         splittingMonthsOver limit: Int = FileSection.dayThreshold) -> [FileSection] {
        let (conditions, values) = Self.filters(query)
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        switch grouping {
        case .none:
            return []
        case .date:
            // Counted here rather than in SQL, so months follow the calendar's time zone.
            let sql = "SELECT \(Self.made), bytes FROM files \(filter) ORDER BY \(Self.made) DESC"
            let dated = (try? statement(sql).rows(values) { row in
                (date: Date(timeIntervalSince1970: row.double(0)), bytes: row.int64(1))
            }) ?? []
            return FileSection.dated(dated, calendar: calendar, limit: limit)
        case .folder:
            let sql = """
                SELECT parent, count(*), coalesce(sum(bytes), 0) FROM files \(filter)
                GROUP BY parent ORDER BY count(*) DESC, parent
                """
            return (try? statement(sql).rows(values) { row in
                FileSection(key: .folder(row.text(0) ?? ""), count: Int(row.int64(1)), bytes: row.int64(2))
            }) ?? []
        case .source:
            let sql = """
                SELECT source, count(*), coalesce(sum(bytes), 0) FROM files \(filter)
                GROUP BY source ORDER BY source IS NULL, count(*) DESC, source
                """
            return (try? statement(sql).rows(values) { row in
                FileSection(key: .source(row.text(0)), count: Int(row.int64(1)), bytes: row.int64(2))
            }) ?? []
        }
    }
}

/// How much of a section the selection takes in.
public enum SectionCoverage: Sendable, Equatable {
    case nothing, part, whole

    public init(of section: Set<Int64>, in selection: Set<Int64>) {
        if section.isEmpty || section.isDisjoint(with: selection) {
            self = .nothing
        } else {
            self = section.isSubset(of: selection) ? .whole : .part
        }
    }
}
