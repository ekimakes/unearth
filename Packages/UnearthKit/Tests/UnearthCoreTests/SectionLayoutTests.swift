import Testing
@testable import UnearthCore

struct SectionLayoutTests {
    // 5, 2 and 7 items, 3 across: 2, 1 and 3 rows under a 40-point header, 100 points a row.
    let layout = SectionLayout(counts: [5, 2, 7], columns: 3, headerHeight: 40, rowHeight: 100)

    @Test func eachSectionIsItsHeaderThenItsRows() {
        #expect(layout.starts == [0, 240, 380])
        #expect(layout.height == 720)
        #expect(layout.rows(in: 0) == 2)
        #expect(layout.rows(in: 2) == 3)
    }

    @Test func findsTheSectionAtAHeight() {
        #expect(layout.section(at: -5) == 0)
        #expect(layout.section(at: 239) == 0)
        #expect(layout.section(at: 240) == 1)
        #expect(layout.section(at: 10_000) == 2)
        #expect(SectionLayout(counts: [], columns: 3, headerHeight: 40, rowHeight: 100).section(at: 0) == nil)
    }

    @Test func onlyTheLinesInViewAreListed() {
        #expect(layout.lines(in: 200..<420) == [
            .init(line: .row(section: 0, row: 1), y: 140), .init(line: .header(section: 1), y: 240),
            .init(line: .row(section: 1, row: 0), y: 280), .init(line: .header(section: 2), y: 380),
        ])
        #expect(layout.lines(in: 700..<900) == [.init(line: .row(section: 2, row: 2), y: 620)])
        #expect(layout.lines(in: 800..<900).isEmpty)
    }

    @Test func knowsWhereEachItemIs() {
        #expect(layout.y(ofItem: 0, in: 0) == 40)
        #expect(layout.y(ofItem: 4, in: 2) == 520)
    }

    @Test func theNextHeaderPushesThePinnedOneUp() {
        #expect(layout.pinnedHeader(at: 100) == .init(section: 0, offset: 0))
        #expect(layout.pinnedHeader(at: 210) == .init(section: 0, offset: -10))
        #expect(layout.pinnedHeader(at: 240) == .init(section: 1, offset: 0))
        #expect(layout.pinnedHeader(at: 700) == .init(section: 2, offset: 0))
    }

    @Test func noColumnsCountsAsOne() {
        #expect(SectionLayout(counts: [2], columns: 0, headerHeight: 10, rowHeight: 10).height == 30)
    }

    @Test func aPointFindsTheItemUnderIt() {
        // 100 points a column; rows start under each 40-point header.
        func item(_ x: Double, _ y: Double) -> GridNavigation.Position? { layout.position(x: x, y: y, columnWidth: 100) }
        #expect(item(0, 40) == .init(section: 0, item: 0))
        #expect(item(250, 139) == .init(section: 0, item: 2))
        #expect(item(150, 140) == .init(section: 0, item: 4))
        #expect(item(50, 450) == .init(section: 2, item: 0))
    }

    @Test func nothingIsUnderAHeaderOrPastTheLastItem() {
        func item(_ x: Double, _ y: Double) -> GridNavigation.Position? { layout.position(x: x, y: y, columnWidth: 100) }
        #expect(item(50, 10) == nil)
        #expect(item(250, 150) == nil)
        #expect(item(350, 50) == nil)
        #expect(item(-1, 50) == nil)
        #expect(item(50, 100_000) == nil)
    }

    @Test func aRowsItemsComeFromTheLayoutItself() {
        #expect(layout.items(inRow: 0, of: 0) == 0..<3)
        #expect(layout.items(inRow: 1, of: 0) == 3..<5)
        #expect(layout.items(inRow: 0, of: 1) == 0..<2)
        // Whatever a row left over from an older layout asks for, it's a range, never a crash.
        #expect(layout.items(inRow: 9, of: 0).isEmpty)
        #expect(layout.items(inRow: 0, of: 7).isEmpty)
    }
}
