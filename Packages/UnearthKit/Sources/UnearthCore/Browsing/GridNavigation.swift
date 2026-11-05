import Foundation

/// Moving through a grid of files with the arrow keys, the way Finder does.
public enum GridNavigation {
    public enum Direction: Sendable {
        case left, right, up, down
    }

    /// Where the selection goes from `index` in a grid of `count` items laid out `columns` across. With nothing
    /// selected, it starts at the first item; it never leaves the grid.
    public static func next(from index: Int?, direction: Direction, columns: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return 0 }
        let columns = max(1, columns)
        let moved = switch direction {
        case .left: index - 1
        case .right: index + 1
        case .up: index - columns >= 0 ? index - columns : index
        // Down from a row above a short last row lands on the last item.
        case .down: index / columns < (count - 1) / columns ? min(index + columns, count - 1) : index
        }
        return min(max(moved, 0), count - 1)
    }

    /// An item in a grid split into sections.
    public struct Position: Sendable, Hashable, Comparable {
        public let section: Int
        public let item: Int

        public init(section: Int, item: Int) {
            self.section = section
            self.item = item
        }

        public static func < (left: Position, right: Position) -> Bool {
            (left.section, left.item) < (right.section, right.item)
        }
    }

    /// Where a ⇧ range starts from: a file, and the place it was at. A reload can put another file at that place,
    /// so the place holds only while the same file is still there and something is still selected.
    public struct Anchor: Sendable, Equatable {
        public let position: Position
        public let file: Int64

        public init(position: Position, file: Int64) {
            self.position = position
            self.file = file
        }

        /// The anchor's place, given the file there now. Nil means a ⇧-click is a plain click.
        public func position(fileThere current: Int64?, hasSelection: Bool) -> Position? {
            hasSelection && current == file ? position : nil
        }
    }

    /// Where the selection goes in a grid split into sections of `counts` items, each section starting a new row.
    /// Up and down cross into the next section in the same column, left and right run on from the end of one
    /// section to the start of the next, and empty sections are skipped. With nothing selected, it starts at the
    /// first item; it never leaves the grid.
    public static func next(from position: Position?, direction: Direction, columns: Int, counts: [Int]) -> Position? {
        let columns = max(1, columns)
        func filled(after section: Int) -> Int? { counts.indices.first { $0 > section && counts[$0] > 0 } }
        func filled(before section: Int) -> Int? { counts.indices.last { $0 < section && counts[$0] > 0 } }
        guard let position, counts.indices.contains(position.section), counts[position.section] > 0 else {
            return filled(after: -1).map { Position(section: $0, item: 0) }
        }
        let section = position.section
        let count = counts[section]
        let item = min(max(position.item, 0), count - 1)
        let column = item % columns
        let stay = Position(section: section, item: item)
        switch direction {
        case .left:
            if item > 0 { return Position(section: section, item: item - 1) }
            return filled(before: section).map { Position(section: $0, item: counts[$0] - 1) } ?? stay
        case .right:
            if item + 1 < count { return Position(section: section, item: item + 1) }
            return filled(after: section).map { Position(section: $0, item: 0) } ?? stay
        case .up:
            if item >= columns { return Position(section: section, item: item - columns) }
            guard let previous = filled(before: section) else { return stay }
            let lastRow = (counts[previous] - 1) / columns * columns
            return Position(section: previous, item: min(lastRow + column, counts[previous] - 1))
        case .down:
            // Down from a row above a short last row lands on the last item, as in a grid without sections.
            if item / columns < (count - 1) / columns { return Position(section: section, item: min(item + columns, count - 1)) }
            guard let following = filled(after: section) else { return stay }
            return Position(section: following, item: min(column, counts[following] - 1))
        }
    }

    /// The items from the anchor to the cursor, for extending a selection with Shift.
    public static func range(anchor: Int, cursor: Int) -> ClosedRange<Int> {
        min(anchor, cursor)...max(anchor, cursor)
    }

    /// How many cards fit across `width`.
    public static func columns(width: Double, itemWidth: Double, spacing: Double) -> Int {
        max(1, Int((width + spacing) / (itemWidth + spacing)))
    }
}
