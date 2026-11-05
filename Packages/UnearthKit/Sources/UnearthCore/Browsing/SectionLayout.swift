import Foundation

/// Where everything sits in a grid split into sections, each a header and then rows of items, all of a fixed
/// height. Knowing it up front lets a screen draw only what's in view and jump straight to any section, however
/// many files there are.
public struct SectionLayout: Sendable, Equatable {
    public enum Line: Sendable, Hashable {
        case header(section: Int)
        case row(section: Int, row: Int)
    }

    /// A line and the height its top is at.
    public struct Placed: Sendable, Hashable {
        public let line: Line
        public let y: Double

        public init(line: Line, y: Double) {
            self.line = line
            self.y = y
        }
    }

    /// The header kept at the top of the view.
    public struct Pinned: Sendable, Equatable {
        public let section: Int
        /// How far the next section's header is pushing it up: zero or less.
        public let offset: Double

        public init(section: Int, offset: Double) {
            self.section = section
            self.offset = offset
        }
    }

    public let counts: [Int]
    public let columns: Int
    public let headerHeight: Double
    public let rowHeight: Double
    /// Where each section's header starts.
    public let starts: [Double]
    /// All of it, top to bottom.
    public let height: Double

    public init(counts: [Int], columns: Int, headerHeight: Double, rowHeight: Double) {
        let columns = max(1, columns)
        var starts: [Double] = []
        var y = 0.0
        for count in counts {
            starts.append(y)
            y += headerHeight + Double((count + columns - 1) / columns) * rowHeight
        }
        self.counts = counts
        self.columns = columns
        self.headerHeight = headerHeight
        self.rowHeight = rowHeight
        self.starts = starts
        height = y
    }

    public func rows(in section: Int) -> Int {
        (counts[section] + columns - 1) / columns
    }

    /// The items in a row of a section, empty if this layout has no such row.
    public func items(inRow row: Int, of section: Int) -> Range<Int> {
        guard counts.indices.contains(section), row >= 0 else { return 0..<0 }
        let start = row * columns
        return start..<max(start, min(start + columns, counts[section]))
    }

    /// The section at height `y`: the last one starting at or above it.
    public func section(at y: Double) -> Int? {
        guard !starts.isEmpty else { return nil }
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= y { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The headers and rows that reach into `range`, top to bottom.
    public func lines(in range: Range<Double>) -> [Placed] {
        guard var section = section(at: range.lowerBound) else { return [] }
        var placed: [Placed] = []
        while section < counts.count, starts[section] < range.upperBound {
            let top = starts[section]
            if top + headerHeight > range.lowerBound { placed.append(Placed(line: .header(section: section), y: top)) }
            let rowsTop = top + headerHeight
            var row = max(0, Int(((range.lowerBound - rowsTop) / rowHeight).rounded(.down)))
            while row < rows(in: section) {
                let y = rowsTop + Double(row) * rowHeight
                guard y < range.upperBound else { break }
                if y + rowHeight > range.lowerBound { placed.append(Placed(line: .row(section: section, row: row), y: y)) }
                row += 1
            }
            section += 1
        }
        return placed
    }

    /// The top of the row holding `item` in `section`.
    public func y(ofItem item: Int, in section: Int) -> Double {
        starts[section] + headerHeight + Double(item / columns) * rowHeight
    }

    /// The item at a point, with columns `columnWidth` apart. Nil over a header or past a section's last item.
    public func position(x: Double, y: Double, columnWidth: Double) -> GridNavigation.Position? {
        guard let section = section(at: y), x >= 0, columnWidth > 0 else { return nil }
        let rowsTop = starts[section] + headerHeight
        guard y >= rowsTop else { return nil }
        let column = Int(x / columnWidth)
        let item = Int((y - rowsTop) / rowHeight) * columns + column
        guard column < columns, item < counts[section] else { return nil }
        return GridNavigation.Position(section: section, item: item)
    }

    /// The header pinned at the top of a view scrolled to `y`, pushed up as the next one arrives.
    public func pinnedHeader(at y: Double) -> Pinned? {
        guard let section = section(at: y) else { return nil }
        let next = section + 1 < starts.count ? starts[section + 1] : .infinity
        return Pinned(section: section, offset: min(0, next - y - headerHeight))
    }
}
