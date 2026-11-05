import Foundation
import Observation
import UnearthCore

/// One screen's files split into sections (months, folders or download sources), each loaded a page at a time as
/// it comes into view: a screen of 50,000 photos opens at once and holds only what has been looked at.
@MainActor @Observable
final class Timeline {
    /// Where the files come from.
    enum Source {
        /// The Library: sections and pages are queries on the index.
        case library(LibraryModel, query: SearchQuery, grouping: FileGrouping, sort: FileSort)
        /// A folder's listing, already split into sections, with which entries are folders.
        case files([(section: FileSection, files: [IndexedFile])], folders: Set<Int64>)
    }

    typealias Position = GridNavigation.Position

    private struct Page: Hashable {
        let section: FileSection.Key
        let number: Int
    }

    /// One page of a section's files. Each is observed on its own, so a row redraws only when its own page arrives.
    @MainActor @Observable
    final class FilePage {
        var files: [IndexedFile] = []
    }

    static let pageSize = 200

    private(set) var sections: [FileSection] = []
    /// False until the first sections arrive.
    private(set) var isLoaded = false
    /// Bumped whenever the sections change, so rows and tiles know their files may have too.
    private(set) var loads = 0
    /// Bumped when everything starts over, which also goes back to the top.
    private(set) var restarts = 0
    @ObservationIgnored private var pages: [Page: FilePage] = [:]
    /// The IDs in each section whose header is on screen, to tell whether all of it is selected.
    private var sectionIDs: [FileSection.Key: Set<Int64>] = [:]
    /// A few files spread across each month and year, for the Years and Months views.
    @ObservationIgnored private var previews: [String: [IndexedFile]] = [:]
    /// Every file loaded so far, by ID: what the selection bar and the actions work on.
    @ObservationIgnored private(set) var known: [Int64: IndexedFile] = [:]
    /// The entries of a folder's listing that are folders.
    @ObservationIgnored private(set) var folders: Set<Int64> = []
    @ObservationIgnored private var source: Source?
    @ObservationIgnored private var requested: Set<Page> = []
    @ObservationIgnored private var requestedIDs: Set<FileSection.Key> = []
    /// Bumped by every load, so what arrives for an older one is dropped.
    @ObservationIgnored private var generation = 0
    let calendar = FileSection.gregorian(like: .current)

    var count: Int { sections.reduce(0) { $0 + $1.count } }
    var counts: [Int] { sections.map(\.count) }
    var years: [FileYear] { FileSection.years(sections) }
    /// Whether every file here is in the one folder being listed, so none needs to say which.
    var isOneFolder: Bool { if case .files = source { true } else { false } }

    /// Shows `source`. With `keepingPages` (the Library changed), the files on screen stay until their fresh pages
    /// arrive; otherwise everything starts over (new filters, sort or grouping).
    func load(_ source: Source, keepingPages: Bool) async {
        generation += 1
        let current = generation
        let sections: [FileSection]
        switch source {
        case .library(let library, let query, let grouping, _):
            sections = await library.sections(matching: query, by: grouping, calendar: calendar)
        case .files(let grouped, _):
            sections = grouped.map(\.section)
        }
        guard current == generation else { return }
        // Pages on their way were asked of the old source: what they were for is asked again below.
        generation += 1
        let reload = keepingPages ? Set(pages.keys).filter { pages[$0]?.files.isEmpty == false }.union(requested) : []
        let reloadIDs = keepingPages ? Set(sectionIDs.keys) : []
        let sameSections = keepingPages && sections == self.sections
        self.source = source
        if !sameSections { self.sections = sections }
        requested = []
        requestedIDs = []
        if !keepingPages {
            pages = [:]
            sectionIDs = [:]
            previews = [:]
            known = [:]
            restarts += 1
        }
        isLoaded = true
        if !sameSections { loads += 1 }
        let keys = Set(sections.map(\.key))
        sectionIDs = sectionIDs.filter { keys.contains($0.key) }
        if case .files(let grouped, let folders) = source {
            self.folders = folders
            var filled = Set<Page>()
            for (section, files) in grouped {
                for start in stride(from: 0, to: files.count, by: Self.pageSize) {
                    let key = Page(section: section.key, number: start / Self.pageSize)
                    page(key).files = Array(files[start..<min(start + Self.pageSize, files.count)])
                    filled.insert(key)
                }
                remember(files)
            }
            for (key, page) in pages where !filled.contains(key) { page.files = [] }
        } else {
            pages = pages.filter { keys.contains($0.key.section) }
            for page in reload where keys.contains(page.section) { request(page) }
        }
        for section in sections.indices where reloadIDs.contains(sections[section].key) { needIDs(in: section) }
    }

    /// Keeps these files, as the Library has them now, for the selection bar and the actions.
    func remember(_ files: [IndexedFile]) {
        for file in files { known[file.id] = file }
    }

    // MARK: - Files

    /// A page's box, made on first use: a row watching it hears when the files arrive.
    private func page(_ key: Page) -> FilePage {
        if let page = pages[key] { return page }
        let page = FilePage()
        pages[key] = page
        return page
    }

    /// The file at a position, once its page has arrived.
    func file(at position: Position) -> IndexedFile? {
        guard sections.indices.contains(position.section), position.item >= 0 else { return nil }
        let index = position.item % Self.pageSize
        let files = page(Page(section: sections[position.section].key, number: position.item / Self.pageSize)).files
        return files.indices.contains(index) ? files[index] : nil
    }

    /// Asks for the pages holding these items of a section, unless they're here or on their way.
    func need(section: Int, items: Range<Int>) {
        guard sections.indices.contains(section), !items.isEmpty else { return }
        let key = sections[section].key
        for number in (items.lowerBound / Self.pageSize)...((items.upperBound - 1) / Self.pageSize) {
            request(Page(section: key, number: number))
        }
    }

    private func request(_ page: Page) {
        guard case .library(let library, let query, _, let sort) = source, !requested.contains(page),
              let section = sections.first(where: { $0.key == page.section }) else { return }
        requested.insert(page)
        let current = generation
        let narrowed = section.query(within: query, calendar: calendar)
        Task {
            let files = await library.files(matching: narrowed, sort: sort, limit: Self.pageSize,
                                            offset: page.number * Self.pageSize)
            guard current == generation else { return }
            self.page(page).files = files
            remember(files)
        }
    }

    /// The file at a position, loading it if it isn't here yet.
    func file(loadingAt position: Position) async -> IndexedFile? {
        if let file = file(at: position) { return file }
        return await files(in: position.section, items: position.item..<(position.item + 1)).first
    }

    /// All of a section's files, in the order shown.
    func files(in section: Int) async -> [IndexedFile] {
        guard sections.indices.contains(section) else { return [] }
        return await files(in: section, items: 0..<sections[section].count)
    }

    /// The files from one position to another, both included, in the order shown.
    func files(from start: Position, through end: Position) async -> [IndexedFile] {
        guard start <= end else { return await files(from: end, through: start) }
        var files: [IndexedFile] = []
        for section in start.section...end.section where sections.indices.contains(section) {
            let first = section == start.section ? start.item : 0
            let last = section == end.section ? end.item : sections[section].count - 1
            if first <= last { files += await self.files(in: section, items: first..<(last + 1)) }
        }
        return files
    }

    /// Every file on the screen.
    func allFiles() async -> [IndexedFile] {
        switch source {
        case .library(let library, let query, _, let sort):
            let files = await library.files(matching: query, sort: sort, limit: Int(Int32.max), offset: 0)
            remember(files)
            return files
        case .files(let grouped, _):
            return grouped.flatMap(\.files)
        case nil:
            return []
        }
    }

    private func files(in section: Int, items: Range<Int>) async -> [IndexedFile] {
        guard sections.indices.contains(section), !items.isEmpty else { return [] }
        guard case .library(let library, let query, _, let sort) = source else {
            return items.compactMap { file(at: Position(section: section, item: $0)) }
        }
        let narrowed = sections[section].query(within: query, calendar: calendar)
        let files = await library.files(matching: narrowed, sort: sort, limit: items.count, offset: items.lowerBound)
        remember(files)
        return files
    }

    // MARK: - Whole sections

    /// The IDs in a section, once `needIDs` has loaded them.
    func ids(in section: Int) -> Set<Int64>? {
        sections.indices.contains(section) ? sectionIDs[sections[section].key] : nil
    }

    /// How many sections are wholly selected, of those whose IDs have loaded.
    func wholeSections(in selection: Set<Int64>) -> Int {
        sections.indices.count { index in
            ids(in: index).map { SectionCoverage(of: $0, in: selection) == .whole } ?? false
        }
    }

    func needIDs(in section: Int) {
        guard sections.indices.contains(section), !requestedIDs.contains(sections[section].key) else { return }
        let fileSection = sections[section]
        requestedIDs.insert(fileSection.key)
        switch source {
        case .library(let library, let query, _, _):
            let current = generation
            let narrowed = fileSection.query(within: query, calendar: calendar)
            Task {
                let ids = await library.ids(matching: narrowed)
                guard current == generation else { return }
                sectionIDs[fileSection.key] = Set(ids)
            }
        case .files(let grouped, _):
            sectionIDs[fileSection.key] = Set(grouped.first { $0.section.key == fileSection.key }?.files.map(\.id) ?? [])
        case nil:
            break
        }
    }

    // MARK: - Pictures for the Years and Months views

    /// What a year's tile has shown before, for drawing it at once.
    func cachedPreviews(of year: FileYear) -> [IndexedFile] { previews["y\(year.year)"] ?? [] }
    func cachedPreviews(of month: FileSection) -> [IndexedFile] { previews["\(month.key)"] ?? [] }

    /// `count` files spread across the year, so its tile isn't one burst of the same shot.
    func previews(of year: FileYear, count: Int) async -> [IndexedFile] {
        await previews("y\(year.year)", in: year.months, total: year.count, count: count) { year.query(within: $0, calendar: $1) }
    }

    func previews(of month: FileSection, count: Int) async -> [IndexedFile] {
        await previews("\(month.key)", in: [month], total: month.count, count: count) { month.query(within: $0, calendar: $1) }
    }

    private func previews(_ id: String, in months: [FileSection], total: Int, count: Int,
                          narrow: (SearchQuery, Calendar) -> SearchQuery) async -> [IndexedFile] {
        let picks = min(count, total)
        // The middle of each equal stretch: one pick is the middle of the month.
        let offsets = (0..<picks).map { (2 * $0 + 1) * total / (2 * picks) }
        var files: [IndexedFile] = []
        switch source {
        case .library(let library, let query, _, _):
            let current = generation
            let narrowed = narrow(query, calendar)
            for offset in offsets {
                files += await library.files(matching: narrowed, sort: .made, limit: 1, offset: offset)
            }
            guard current == generation else { return files }
        case .files(let grouped, _):
            // A big month is in here as its days.
            let keys = Set(months.map(\.key))
            let all = grouped.filter { keys.contains($0.section.key.containingMonth ?? $0.section.key) }.flatMap(\.files)
            files = offsets.compactMap { all.indices.contains($0) ? all[$0] : nil }
        case nil:
            return []
        }
        previews[id] = files
        return files
    }

    /// Loads the files and section IDs a stretch of the timeline shows, waiting for them (snapshots).
    func loadVisible(_ layout: SectionLayout, window: Range<Double>) async {
        for placed in layout.lines(in: window) {
            switch placed.line {
            case .header(let section):
                needIDs(in: section)
            case .row(let section, let row):
                for item in layout.items(inRow: row, of: section) where file(at: Position(section: section, item: item)) == nil {
                    let key = Page(section: sections[section].key, number: item / Self.pageSize)
                    requested.insert(key)
                    let offset = key.number * Self.pageSize
                    page(key).files = await files(in: section, items: offset..<min(offset + Self.pageSize, sections[section].count))
                }
            }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while sections.indices.contains(where: { requestedIDs.contains(sections[$0].key) && sectionIDs[sections[$0].key] == nil }),
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Loads every tile's pictures for the Years and Months views, waiting for them (snapshots).
    func loadPreviews(count: Int) async {
        for year in years { _ = await previews(of: year, count: count) }
        for month in sections { _ = await previews(of: month, count: 1) }
    }
}
