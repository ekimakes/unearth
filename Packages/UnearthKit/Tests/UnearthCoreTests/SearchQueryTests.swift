import Foundation
import Testing
@testable import UnearthCore

struct SearchQueryTests {
    /// Wednesday 4 November 2026, noon UTC; weeks start on Monday.
    static let now = Date(timeIntervalSince1970: 1_793_793_600)
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    static func parse(_ input: String) -> SearchQuery {
        SearchQuery.parse(input, now: now, calendar: calendar)
    }

    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test func screenshotsWithInvoice() {
        let query = Self.parse("screenshots with invoice")
        #expect(query.kinds == [.screenshot])
        #expect(query.text == "invoice")
    }

    @Test func videosOverOneGB() {
        let query = Self.parse("videos over 1 GB")
        #expect(query.kinds == [.video])
        #expect(query.minBytes == 1_000_000_000)
        #expect(query.text.isEmpty)
        #expect(Self.parse("zips under 50mb").maxBytes == 50_000_000)
        #expect(Self.parse("files bigger than 1.5 gb").minBytes == 1_500_000_000)
    }

    /// "Last week" counts back seven days from now: on a Wednesday, Monday's files are part of it.
    @Test func pdfsFromLastWeek() {
        let query = Self.parse("pdfs from last week")
        #expect(query.extensions == ["pdf"])
        #expect(query.kinds.isEmpty)
        #expect(query.added == DateInterval(start: Self.now.addingTimeInterval(-7 * 86_400), end: Self.now))
        #expect(query.addedLabel == "Past week")
        #expect(query.source == nil)
        #expect(query.text.isEmpty)
    }

    /// Examples from real use.
    @Test func imagesFromLastWeekAndPDFsFromTheLastMonth() {
        let images = Self.parse("images from last week")
        #expect(images.kinds == [.image, .screenshot])
        #expect(images.added == DateInterval(start: Self.now.addingTimeInterval(-7 * 86_400), end: Self.now))
        #expect(images.text.isEmpty)
        let pdfs = Self.parse("PDFs from the last month")
        #expect(pdfs.extensions == ["pdf"])
        #expect(pdfs.added == DateInterval(start: Self.day(2026, 10, 4).addingTimeInterval(12 * 3_600), end: Self.now))
        #expect(pdfs.addedLabel == "Past month")
        #expect(pdfs.text.isEmpty)
    }

    @Test func pastSpansWithCounts() {
        let videos = Self.parse("videos from the past 3 months")
        #expect(videos.kinds == [.video])
        #expect(videos.added == DateInterval(start: Self.day(2026, 8, 4).addingTimeInterval(12 * 3_600), end: Self.now))
        #expect(videos.addedLabel == "Past 3 months")
        #expect(Self.parse("documents within the last 2 weeks").addedLabel == "Past 2 weeks")
        #expect(Self.parse("this past week").addedLabel == "Past week")
        #expect(Self.parse("screenshots over the past year").addedLabel == "Past year")
        // "Over" still means size when a size follows.
        #expect(Self.parse("videos over 2 gb").minBytes == 2_000_000_000)
        #expect(Self.parse("photos of the beach").kinds == [.image])
    }

    @Test func otherDates() {
        #expect(Self.parse("photos today").added == DateInterval(start: Self.day(2026, 11, 4), end: Self.day(2026, 11, 5)))
        #expect(Self.parse("added this month").added == DateInterval(start: Self.day(2026, 11, 1), end: Self.day(2026, 12, 1)))
        let recent = Self.parse("images last 30 days")
        #expect(recent.added == DateInterval(start: Self.now.addingTimeInterval(-30 * 86_400), end: Self.now))
        #expect(recent.addedLabel == "Past 30 days")
    }

    @Test func fromChatGPT() {
        #expect(Self.parse("from chatgpt").source == "ChatGPT")
        #expect(Self.parse("invoices from google drive").source == "Google Drive")
        #expect(Self.parse("invoices from google drive").text == "invoices")
        #expect(Self.parse("from example.com").source == "example.com")
    }

    @Test func plainWordsAreText() {
        let query = Self.parse("tax return 2025")
        #expect(query.text == "tax return 2025")
        #expect(query.kinds.isEmpty && query.extensions.isEmpty && query.minBytes == nil && query.added == nil)
        #expect(Self.parse("").isEmpty)
        #expect(Self.parse("show me all my photos of dogs").text == "dogs")
    }

    @Test func quotedTextIsNeverAFilter() {
        let query = Self.parse("\"last week\" notes")
        #expect(query.added == nil)
        #expect(query.text == "last week notes")
    }

    /// Found by review: a size too big for 64 bits crashed the app as the user typed.
    @Test func hugeNumbersNeverCrash() {
        #expect(Self.parse("videos over 10000000000 gb").minBytes == Int64.max)
        #expect(Self.parse("files under 99999999999999999999 tb").maxBytes == Int64.max)
        #expect(Self.parse("images from the last 99999999999 days").added == nil)
    }

    @Test func chipsRoundTripAndRemove() {
        let query = Self.parse("screenshots pdfs over 10 MB this week from slack receipt")
        #expect(query.chips.map(\.label) == ["Screenshots", "PDF", "Over 10 MB", "This week", "From Slack"])
        #expect(query.text == "receipt")
        for chip in query.chips {
            let smaller = query.removing(chip)
            #expect(smaller.chips.count == query.chips.count - 1)
            #expect(!smaller.chips.contains(chip))
            #expect(smaller.text == "receipt")
        }
        #expect(query.removing(.added(query.added!, label: "This week")).addedLabel == nil)
    }
}
