import Testing
@testable import UnearthCore

struct GridNavigationTests {
    @Test func arrowsMoveAcrossAndDownTheGrid() {
        // 10 items, 4 columns: rows 0-3, 4-7, 8-9.
        #expect(GridNavigation.next(from: 5, direction: .right, columns: 4, count: 10) == 6)
        #expect(GridNavigation.next(from: 5, direction: .left, columns: 4, count: 10) == 4)
        #expect(GridNavigation.next(from: 5, direction: .down, columns: 4, count: 10) == 9)
        #expect(GridNavigation.next(from: 5, direction: .up, columns: 4, count: 10) == 1)
    }

    @Test func movesStopAtTheEdges() {
        #expect(GridNavigation.next(from: 0, direction: .left, columns: 4, count: 10) == 0)
        #expect(GridNavigation.next(from: 9, direction: .right, columns: 4, count: 10) == 9)
        #expect(GridNavigation.next(from: 2, direction: .up, columns: 4, count: 10) == 2)
        // Down from a row above a short last row lands on the last item.
        #expect(GridNavigation.next(from: 7, direction: .down, columns: 4, count: 10) == 9)
        #expect(GridNavigation.next(from: 9, direction: .down, columns: 4, count: 10) == 9)
    }

    @Test func nothingSelectedStartsAtTheFirstItem() {
        #expect(GridNavigation.next(from: nil, direction: .down, columns: 4, count: 10) == 0)
        #expect(GridNavigation.next(from: nil, direction: .right, columns: 4, count: 0) == nil)
    }

    @Test func listsMoveOneRowAtATime() {
        #expect(GridNavigation.next(from: 3, direction: .down, columns: 1, count: 10) == 4)
        #expect(GridNavigation.next(from: 3, direction: .up, columns: 1, count: 10) == 2)
    }

    @Test func shiftExtendsFromTheAnchor() {
        #expect(GridNavigation.range(anchor: 6, cursor: 2) == 2...6)
        #expect(GridNavigation.range(anchor: 2, cursor: 6) == 2...6)
    }

    @Test func columnsComeFromTheWidth() {
        #expect(GridNavigation.columns(width: 600, itemWidth: 144, spacing: 14) == 3)
        #expect(GridNavigation.columns(width: 100, itemWidth: 144, spacing: 14) == 1)
    }
}

struct SectionedGridNavigationTests {
    // 5, 2 and 7 items, 3 across. Section 0: 0 1 2 / 3 4. Section 1: 0 1. Section 2: 0 1 2 / 3 4 5 / 6.
    let counts = [5, 2, 7]

    func next(_ section: Int?, _ item: Int, _ direction: GridNavigation.Direction, counts: [Int]? = nil) -> GridNavigation.Position? {
        GridNavigation.next(from: section.map { GridNavigation.Position(section: $0, item: item) }, direction: direction,
                            columns: 3, counts: counts ?? self.counts)
    }

    @Test func downCrossesIntoTheNextSectionInTheSameColumn() {
        #expect(next(0, 1, .down) == .init(section: 0, item: 4))
        #expect(next(0, 2, .down) == .init(section: 0, item: 4))
        #expect(next(0, 4, .down) == .init(section: 1, item: 1))
        #expect(next(0, 3, .down) == .init(section: 1, item: 0))
        #expect(next(1, 1, .down) == .init(section: 2, item: 1))
    }

    @Test func upCrossesIntoThePreviousSectionsLastRow() {
        #expect(next(1, 0, .up) == .init(section: 0, item: 3))
        #expect(next(1, 1, .up) == .init(section: 0, item: 4))
        #expect(next(2, 2, .up) == .init(section: 1, item: 1))
        #expect(next(2, 4, .up) == .init(section: 2, item: 1))
    }

    @Test func leftAndRightRunOnAcrossSections() {
        #expect(next(0, 4, .right) == .init(section: 1, item: 0))
        #expect(next(1, 0, .left) == .init(section: 0, item: 4))
    }

    @Test func movesStopAtTheEnds() {
        #expect(next(0, 0, .left) == .init(section: 0, item: 0))
        #expect(next(0, 1, .up) == .init(section: 0, item: 1))
        #expect(next(2, 6, .right) == .init(section: 2, item: 6))
        #expect(next(2, 6, .down) == .init(section: 2, item: 6))
    }

    @Test func startsAtTheFirstItemAndSkipsEmptySections() {
        #expect(next(nil, 0, .down) == .init(section: 0, item: 0))
        #expect(next(nil, 0, .down, counts: [0, 3]) == .init(section: 1, item: 0))
        #expect(next(nil, 0, .down, counts: []) == nil)
        #expect(next(0, 1, .down, counts: [2, 0, 2]) == .init(section: 2, item: 1))
    }

    @Test func positionsOrderBySectionThenItem() {
        #expect(GridNavigation.Position(section: 0, item: 9) < GridNavigation.Position(section: 1, item: 0))
        #expect(GridNavigation.Position(section: 1, item: 2) < GridNavigation.Position(section: 1, item: 3))
    }

    @Test func anAnchorHoldsOnlyWhileItsFileIsThere() {
        let anchor = GridNavigation.Anchor(position: .init(section: 5, item: 10), file: 42)
        #expect(anchor.position(fileThere: 42, hasSelection: true) == .init(section: 5, item: 10))
        // A reload moved the files: another one is there now, or none.
        #expect(anchor.position(fileThere: 43, hasSelection: true) == nil)
        #expect(anchor.position(fileThere: nil, hasSelection: true) == nil)
        // Nothing is selected any more, so there's nothing to extend.
        #expect(anchor.position(fileThere: 42, hasSelection: false) == nil)
    }
}
