import Foundation
import Testing
@testable import UnearthCore

extension FileIndex {
    /// How SQLite means to answer a page of `query`.
    func plan(of query: SearchQuery, sort: FileSort) -> String {
        let (conditions, values) = Self.filters(query)
        let sql = "EXPLAIN QUERY PLAN SELECT \(Self.columns) FROM files WHERE \(conditions.joined(separator: " AND ")) ORDER BY \(Self.order(sort)) LIMIT 1 OFFSET 5"
        return ((try? db.prepare(sql).rows(values) { $0.text(3) ?? "" }) ?? []).joined(separator: "; ")
    }
}

struct FileSectionsTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int = 15, hour: Int = 12, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// `made` is the creation date; the modified date is the same unless given.
    static func record(_ path: String, made: Date?, modified: Date? = nil, bytes: Int64 = 100,
                       source: String? = nil) -> IndexedFileRecord {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        return IndexedFileRecord(
            path: path, name: name, parent: parent, folder: (parent as NSString).lastPathComponent, kind: .image,
            fileExtension: FileClassifier.fileExtension(name), bytes: bytes, created: made,
            modified: modified ?? made ?? Date(timeIntervalSince1970: 0), added: date(2026, 11, 1), source: source,
            isCloudOnly: false)
    }

    static let records = [
        record("/u/Pictures/a.jpg", made: date(2026, 10), bytes: 10, source: "ChatGPT"),
        record("/u/Pictures/b.jpg", made: date(2026, 10), bytes: 20, source: "ChatGPT"),
        record("/u/Pictures/Trip/c.jpg", made: date(2026, 9), bytes: 30, source: "X"),
        record("/u/Desktop/d.jpg", made: date(2025, 12), bytes: 40),
        // No creation date on record: when it was last changed stands in.
        record("/u/Desktop/e.jpg", made: nil, modified: date(2024, 3), bytes: 50),
    ]

    static func library(_ records: [IndexedFileRecord] = records) async throws -> FileIndex {
        let index = try FileIndex.inMemory()
        try await index.upsert(records, generation: await index.beginPass())
        return index
    }

    @Test func monthsAreNewestFirstByWhenFilesWereMade() async throws {
        let months = try await Self.library().sections(matching: SearchQuery(), by: .date, calendar: Self.calendar)
        #expect(months.map(\.key) == [.month(year: 2026, month: 10), .month(year: 2026, month: 9),
                                      .month(year: 2025, month: 12), .month(year: 2024, month: 3)])
        #expect(months.map(\.count) == [2, 1, 1, 1])
        #expect(months.map(\.bytes) == [30, 30, 40, 50])
    }

    @Test func aCopyIsDatedByWhenItWasLastChanged() async throws {
        // Copying or unzipping creates the file anew but keeps the date it was last changed.
        let copy = Self.record("/u/Pictures/old.jpg", made: Self.date(2026, 10), modified: Self.date(2019, 5))
        let months = try await Self.library([copy]).sections(matching: SearchQuery(), by: .date, calendar: Self.calendar)
        #expect(months.map(\.key) == [.month(year: 2019, month: 5)])
    }

    @Test func monthsFollowTheCalendarsTimeZone() async throws {
        // Half past midnight on 1 November in Amsterdam is still 31 October in UTC.
        let night = Self.record("/u/Pictures/night.jpg", made: Self.date(2026, 11, 1, hour: 0, minute: 30))
        let months = try await Self.library([night]).sections(matching: SearchQuery(), by: .date, calendar: Self.calendar)
        #expect(months.map(\.key) == [.month(year: 2026, month: 11)])
    }

    @Test func foldersWithTheMostFilesComeFirst() async throws {
        let folders = try await Self.library().sections(matching: SearchQuery(), by: .folder, calendar: Self.calendar)
        #expect(folders.map(\.key) == [.folder("/u/Desktop"), .folder("/u/Pictures"), .folder("/u/Pictures/Trip")])
        #expect(folders.map(\.count) == [2, 2, 1])
    }

    @Test func sourcesWithTheMostFilesComeFirstAndUnknownLast() async throws {
        let sources = try await Self.library().sections(matching: SearchQuery(), by: .source, calendar: Self.calendar)
        #expect(sources.map(\.key) == [.source("ChatGPT"), .source("X"), .source(nil)])
        #expect(sources.map(\.count) == [2, 1, 2])
    }

    @Test func noGroupingMeansNoSections() async throws {
        #expect(try await Self.library().sections(matching: SearchQuery(), by: .none, calendar: Self.calendar).isEmpty)
    }

    @Test func aSectionsQueryFindsJustItsFiles() async throws {
        let index = try await Self.library()
        func names(_ key: FileSection.Key) async -> Set<String> {
            let query = FileSection(key: key, count: 0, bytes: 0).query(within: SearchQuery(), calendar: Self.calendar)
            return Set(await index.files(matching: query, sort: .made, limit: 10, offset: 0).map(\.name))
        }
        #expect(await names(.month(year: 2026, month: 10)) == ["a.jpg", "b.jpg"])
        #expect(await names(.folder("/u/Pictures")) == ["a.jpg", "b.jpg"])
        #expect(await names(.source("ChatGPT")) == ["a.jpg", "b.jpg"])
        #expect(await names(.source(nil)) == ["d.jpg", "e.jpg"])
    }

    @Test func sectionsKeepTheScreensFilters() async throws {
        let index = try await Self.library()
        var bigOnes = SearchQuery()
        bigOnes.minBytes = 25
        let months = await index.sections(matching: bigOnes, by: .date, calendar: Self.calendar)
        #expect(months.map(\.key) == [.month(year: 2026, month: 9), .month(year: 2025, month: 12), .month(year: 2024, month: 3)])
        let pictures = FileSection(key: .folder("/u/Pictures"), count: 0, bytes: 0).query(within: bigOnes, calendar: Self.calendar)
        #expect(await index.files(matching: pictures, sort: .made, limit: 10, offset: 0).isEmpty)
    }

    @Test func filesSortByWhenMadeNewestFirst() async throws {
        let files = try await Self.library().files(matching: SearchQuery(), sort: .made, limit: 10, offset: 0)
        // Made at the same moment: the one indexed last comes first, as with every other sort.
        #expect(files.map(\.name) == ["b.jpg", "a.jpg", "c.jpg", "d.jpg", "e.jpg"])
    }

    @Test func yearsAddUpTheirMonths() async throws {
        let years = FileSection.years(
            try await Self.library().sections(matching: SearchQuery(), by: .date, calendar: Self.calendar))
        #expect(years.map(\.year) == [2026, 2025, 2024])
        #expect(years.map(\.count) == [3, 1, 1])
        #expect(years.map(\.bytes) == [60, 40, 50])
        #expect(years.first?.months.map(\.key) == [.month(year: 2026, month: 10), .month(year: 2026, month: 9)])
    }

    @Test func aYearsQueryCoversTheWholeYear() async throws {
        let index = try await Self.library()
        let year = FileSection.years(await index.sections(matching: SearchQuery(), by: .date, calendar: Self.calendar))[0]
        let query = year.query(within: SearchQuery(), calendar: Self.calendar)
        #expect(Set(await index.files(matching: query, sort: .made, limit: 10, offset: 0).map(\.name)) == ["a.jpg", "b.jpg", "c.jpg"])
    }

    @Test func filesInMemoryGroupLikeTheIndex() async throws {
        let index = try await Self.library()
        let files = await index.files(matching: SearchQuery(), sort: .name, limit: 10, offset: 0)
        for grouping in [FileGrouping.date, .folder, .source] {
            let grouped = FileSection.group(files, by: grouping, calendar: Self.calendar)
            #expect(grouped.map(\.section) == (await index.sections(matching: SearchQuery(), by: grouping, calendar: Self.calendar)))
        }
        let byMonth = FileSection.group(files, by: .date, calendar: Self.calendar)
        #expect(byMonth[0].files.map(\.name) == ["b.jpg", "a.jpg"])
        #expect(FileSection.group(files, by: .none, calendar: Self.calendar).isEmpty)
    }

    @Test func aSectionsIDsAndFilesByIDComeBack() async throws {
        let index = try await Self.library()
        let desktop = FileSection(key: .folder("/u/Desktop"), count: 0, bytes: 0).query(within: SearchQuery(), calendar: Self.calendar)
        let ids = await index.ids(matching: desktop)
        #expect(ids.count == 2)
        #expect(Set(await index.files(ids: ids).map(\.name)) == ["d.jpg", "e.jpg"])
        // Files no longer in the index are left out.
        #expect(await index.files(ids: [ids[0], 9_999]).map(\.id) == [ids[0]])
        #expect(await index.files(ids: []).isEmpty)
    }

    @Test func aFoldersSubfoldersStayOutOfItsYears() {
        let sections = [
            FileSection(key: .subfolders, count: 3, bytes: 0), FileSection(key: .month(year: 2026, month: 10), count: 2, bytes: 5),
            FileSection(key: .month(year: 2026, month: 2), count: 2, bytes: 5), FileSection(key: .month(year: 2025, month: 1), count: 1, bytes: 5),
        ]
        #expect(FileSection.years(sections).map(\.year) == [2026, 2025])
        #expect(sections[0].query(within: SearchQuery(), calendar: Self.calendar) == SearchQuery())
    }

    @Test func eachYearStartsAtItsNewestMonth() {
        let sections = [
            FileSection(key: .subfolders, count: 3, bytes: 0), FileSection(key: .month(year: 2026, month: 10), count: 2, bytes: 5),
            FileSection(key: .month(year: 2026, month: 2), count: 2, bytes: 5), FileSection(key: .month(year: 2025, month: 1), count: 1, bytes: 5),
        ]
        #expect(FileSection.yearStarts(sections).map(\.year) == [2026, 2025])
        #expect(FileSection.yearStarts(sections).map(\.section) == [1, 3])
    }

    @Test func monthsAreCalendarMonthsWhateverTheSystemCalendar() async throws {
        // Years repeat across Japanese eras, and in 2023 the Chinese calendar had two second months.
        let index = try await Self.library([
            Self.record("/u/showa.jpg", made: Self.date(1985, 6)), Self.record("/u/reiwa.jpg", made: Self.date(2023, 6)),
            Self.record("/u/second.jpg", made: Self.date(2023, 3, 10)), Self.record("/u/leap.jpg", made: Self.date(2023, 4, 5)),
        ])
        for identifier in [Calendar.Identifier.japanese, .chinese, .buddhist, .hebrew, .gregorian] {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = Self.calendar.timeZone
            let months = await index.sections(matching: SearchQuery(), by: .date, calendar: calendar)
            #expect(months.map(\.key) == [.month(year: 2023, month: 6), .month(year: 2023, month: 4),
                                          .month(year: 2023, month: 3), .month(year: 1985, month: 6)])
            for month in months {
                let query = month.query(within: SearchQuery(), calendar: calendar)
                #expect(await index.files(matching: query, sort: .made, limit: 10, offset: 0).count == 1)
            }
            let years = FileSection.years(months)
            #expect(years.map(\.year) == [2023, 1985])
            #expect(await index.files(matching: years[1].query(within: SearchQuery(), calendar: calendar), sort: .made, limit: 10, offset: 0).map(\.name) == ["showa.jpg"])
            let grouped = FileSection.group(await index.files(matching: SearchQuery(), sort: .name, limit: 10, offset: 0), by: .date, calendar: calendar)
            #expect(grouped.map(\.section) == months)
        }
    }

    @Test func aBigMonthSplitsIntoDays() async throws {
        let index = try await Self.library([
            Self.record("/u/a1.jpg", made: Self.date(2026, 11, 3)), Self.record("/u/a2.jpg", made: Self.date(2026, 11, 3)),
            Self.record("/u/b.jpg", made: Self.date(2026, 11, 1)), Self.record("/u/c.jpg", made: Self.date(2026, 10, 9)),
        ])
        let sections = await index.sections(matching: SearchQuery(), by: .date, calendar: Self.calendar, splittingMonthsOver: 2)
        #expect(sections.map(\.key) == [.day(year: 2026, month: 11, day: 3), .day(year: 2026, month: 11, day: 1),
                                        .month(year: 2026, month: 10)])
        #expect(sections.map(\.count) == [2, 1, 1])
        let day = sections[0].query(within: SearchQuery(), calendar: Self.calendar)
        #expect(Set(await index.files(matching: day, sort: .made, limit: 10, offset: 0).map(\.name)) == ["a1.jpg", "a2.jpg"])
    }

    @Test func daysFollowTheCalendarsTimeZone() async throws {
        // Half past midnight in Amsterdam is still the day before in UTC.
        let index = try await Self.library([
            Self.record("/u/a.jpg", made: Self.date(2026, 11, 3, hour: 0, minute: 30)), Self.record("/u/b.jpg", made: Self.date(2026, 11, 2, hour: 23)),
        ])
        let sections = await index.sections(matching: SearchQuery(), by: .date, calendar: Self.calendar, splittingMonthsOver: 1)
        #expect(sections.map(\.key) == [.day(year: 2026, month: 11, day: 3), .day(year: 2026, month: 11, day: 2)])
    }

    @Test func filesInMemorySplitBigMonthsToo() async throws {
        let index = try await Self.library([
            Self.record("/u/a.jpg", made: Self.date(2026, 11, 3)), Self.record("/u/b.jpg", made: Self.date(2026, 11, 1)),
        ])
        let files = await index.files(matching: SearchQuery(), sort: .name, limit: 10, offset: 0)
        let grouped = FileSection.group(files, by: .date, calendar: Self.calendar, splittingMonthsOver: 1)
        #expect(grouped.map(\.section.key) == [.day(year: 2026, month: 11, day: 3), .day(year: 2026, month: 11, day: 1)])
    }

    @Test func yearsGatherDaysBackIntoTheirMonths() {
        let years = FileSection.years([
            FileSection(key: .day(year: 2026, month: 11, day: 3), count: 2, bytes: 10),
            FileSection(key: .day(year: 2026, month: 11, day: 1), count: 1, bytes: 5),
            FileSection(key: .month(year: 2026, month: 10), count: 1, bytes: 7),
            FileSection(key: .day(year: 2025, month: 6, day: 2), count: 4, bytes: 1),
        ])
        #expect(years.map(\.year) == [2026, 2025])
        #expect(years[0].count == 4)
        #expect(years[0].months == [FileSection(key: .month(year: 2026, month: 11), count: 3, bytes: 15),
                                    FileSection(key: .month(year: 2026, month: 10), count: 1, bytes: 7)])
        #expect(years[1].months == [FileSection(key: .month(year: 2025, month: 6), count: 4, bytes: 1)])
    }

    @Test func aDayKnowsItsMonth() {
        #expect(FileSection.Key.day(year: 2026, month: 11, day: 3).containingMonth == .month(year: 2026, month: 11))
        #expect(FileSection.Key.month(year: 2026, month: 11).containingMonth == .month(year: 2026, month: 11))
        #expect(FileSection.Key.folder("/u").containingMonth == nil)
    }

    static func sections(_ counts: [Int], _ key: (Int) -> FileSection.Key) -> [FileSection] {
        counts.enumerated().map { FileSection(key: key($0.offset), count: $0.element, bytes: 0) }
    }

    @Test func batchesMadeInABurstFitFolders() {
        // Most of it arrived in one month, and folders split it far better than that month does.
        let months = Self.sections([26_805, 11_697, 2_557, 2_551, 1_945, 457]) { .month(year: 2026, month: 11 - $0) }
        let folders = Self.sections([8_025, 7_275, 2_722, 2_722, 1_242, 1_176, 945, 933, 18_000 / 20]) { .folder("/f\($0)") }
        #expect(FileSection.fittingGrouping(months: months, folders: folders) == .folder)
    }

    @Test func cameraRollsFitDates() {
        // Everything in one folder, spread over the years.
        let spread = Self.sections(Array(repeating: 400, count: 120)) { .month(year: 2016 + $0 / 12, month: 1 + $0 % 12) }
        #expect(FileSection.fittingGrouping(months: spread, folders: Self.sections([48_000]) { .folder("/f\($0)") }) == .date)
        // A big month, but folders wouldn't split it any better.
        let trip = Self.sections([9_000, 500, 500]) { .month(year: 2026, month: 11 - $0) }
        #expect(FileSection.fittingGrouping(months: trip, folders: Self.sections([9_500, 500]) { .folder("/f\($0)") }) == .date)
    }

    @Test func aFewFilesKeepDates() {
        let months = Self.sections([150]) { .month(year: 2026, month: 11 - $0) }
        #expect(FileSection.fittingGrouping(months: months, folders: Self.sections([50, 50, 50]) { .folder("/f\($0)") }) == .date)
    }

    @Test func splitDaysCountAsTheirMonthWhenFitting() {
        // A month split into days is still one month: its burst must not look spread out.
        let days = Self.sections(Array(repeating: 1_000, count: 30)) { .day(year: 2026, month: 11, day: $0 + 1) }
        let folders = Self.sections(Array(repeating: 1_000, count: 30)) { .folder("/f\($0)") }
        #expect(FileSection.fittingGrouping(months: days, folders: folders) == .folder)
    }

    @Test func anIndexPicksTheGroupingThatFits() async throws {
        let burst = (0..<240).map { Self.record("/u/f\($0 % 12)/\($0).jpg", made: Self.date(2026, 11, 3)) }
        #expect(await (try Self.library(burst)).fittingGrouping(matching: SearchQuery(), calendar: Self.calendar) == .folder)
        let spread = (0..<240).map { Self.record("/u/roll/\($0).jpg", made: Self.date(2016 + $0 % 10, 1 + $0 % 12)) }
        #expect(await (try Self.library(spread)).fittingGrouping(matching: SearchQuery(), calendar: Self.calendar) == .date)
    }

    @Test func theRailNamesYearsThenFillsTheGaps() {
        // Nearly everything is in one November, so years alone would leave the rail bare.
        let sections = [
            FileSection(key: .day(year: 2026, month: 11, day: 4), count: 8_000, bytes: 0),
            FileSection(key: .day(year: 2026, month: 11, day: 3), count: 8_000, bytes: 0),
            FileSection(key: .month(year: 2026, month: 10), count: 8_000, bytes: 0),
            FileSection(key: .month(year: 2025, month: 6), count: 10, bytes: 0),
        ]
        let marks = FileSection.railMarks(sections, positions: [0, 200, 400, 590], spacing: 15)
        #expect(marks.map(\.label) == [.year(2026), .day(year: 2026, month: 11, day: 3), .month(year: 2026, month: 10), .year(2025)])
        #expect(marks.map(\.y) == [0, 200, 400, 590])
    }

    @Test func railMarksNeverCrowd() {
        let sections = Self.sections([5, 5, 5, 5, 5]) { .month(year: 2026 - $0 / 3, month: 11 - $0) }
        let marks = FileSection.railMarks(sections, positions: [0, 5, 10, 20, 300], spacing: 15)
        // Years first, then what still fits.
        #expect(marks.map(\.label) == [.year(2026), .year(2025), .month(year: 2025, month: 7)])
        #expect(marks.map(\.y) == [0, 20, 300])
    }

    @Test func aRailLeavesOutWhatIsntADate() {
        let sections = [FileSection(key: .subfolders, count: 3, bytes: 0), FileSection(key: .month(year: 2026, month: 10), count: 2, bytes: 0)]
        #expect(FileSection.railMarks(sections, positions: [0, 100], spacing: 15).map(\.label) == [.year(2026)])
    }

    @Test func aSectionsFilesAreFoundWithoutWalkingTheWholeLibrary() async throws {
        // On a big library, a folder's first page must not mean reading every image to find the folder's.
        let index = try await Self.library()
        var images = SearchQuery()
        images.kinds = [.image]
        func plan(_ key: FileSection.Key) async -> String {
            await index.plan(of: FileSection(key: key, count: 0, bytes: 0).query(within: images, calendar: Self.calendar), sort: .made)
        }
        for (key, index) in [(FileSection.Key.folder("/u/Pictures"), "files_parent_made"), (.source("X"), "files_source_made"),
                             (.source(nil), "files_source_made"), (.month(year: 2026, month: 10), "files_kind_made")] {
            let answer = await plan(key)
            #expect(answer.contains(index), "\(key): \(answer)")
            #expect(!answer.contains("TEMP B-TREE"), "\(key): \(answer)")
        }
    }
}
