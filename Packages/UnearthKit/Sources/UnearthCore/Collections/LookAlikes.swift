import Foundation

/// Photos that look alike: a burst, an edit and its original, or the same photo saved as HEIC and JPEG.
public struct LookAlikeGroup: Sendable, Identifiable, Equatable {
    public let id: String
    /// In the order they were taken.
    public let files: [IndexedFile]
    /// The best shot, as Vision's aesthetics score sees it.
    public let best: IndexedFile.ID
}

/// Groups the Library's photos with their feature prints. Nothing is selected for the user.
public actor LookAlikeFinder {
    /// The squared distance between prints under which two photos count as alike.
    public static let defaultThreshold: Float = 0.35

    private let index: FileIndex
    private let comparer: any FeaturePrintComparing
    private let scorer: any ShotScoring
    private let isInCodeProject: @Sendable (String) -> Bool
    private let power: any PowerStateProviding
    private let window: TimeInterval
    private let threshold: Float

    /// Photos are compared when they were taken within `window` of each other, or when one's name is the
    /// other's plus a suffix ("IMG_2041 edited") in the same folder.
    public init(
        index: FileIndex, comparer: any FeaturePrintComparing = VisionPrintComparer(),
        scorer: any ShotScoring = VisionShotScorer(), isInCodeProject: @escaping @Sendable (String) -> Bool,
        power: any PowerStateProviding = SystemPowerState(), window: Duration = .seconds(600),
        threshold: Float = LookAlikeFinder.defaultThreshold
    ) {
        self.index = index
        self.comparer = comparer
        self.scorer = scorer
        self.isInCodeProject = isInCodeProject
        self.power = power
        self.window = Double(window.components.seconds) + Double(window.components.attoseconds) / 1e18
        self.threshold = threshold
    }

    /// The groups, the most recent first.
    public func groups() async -> [LookAlikeGroup] {
        let photos = await index.lookAlikePhotos()
            .filter { FileKinds.photoExtensions.contains($0.fileExtension) && !isInCodeProject($0.path) }
            .sorted { Self.taken($0) != Self.taken($1) ? Self.taken($0) < Self.taken($1) : $0.id < $1.id }
        var links = Links(count: photos.count)

        // Same name: HEIC/JPEG pairs always belong together; edits do when they look alike.
        var namePairs: [(Int, Int)] = []
        for (first, second, alwaysAlike) in Self.namePairs(photos) {
            if alwaysAlike { links.join(first, second) } else { namePairs.append((first, second)) }
        }
        let named = await index.prints(ids: namePairs.flatMap { [photos[$0.0].id, photos[$0.1].id] })
        for (first, second) in namePairs where alike(named[photos[first].id], named[photos[second].id]) {
            links.join(first, second)
        }

        // Taken close together. Prints are read a few hundred at a time and dropped once out of the window.
        var prints: [Int64: Data] = [:]
        var read = 0
        var oldest = 0
        for current in photos.indices {
            if Task.isCancelled { return [] }
            if current == read {
                let next = photos[read..<min(photos.count, read + 500)].map(\.id)
                prints.merge(await index.prints(ids: next)) { first, _ in first }
                read += next.count
            }
            while Self.taken(photos[oldest]).distance(to: Self.taken(photos[current])) > window {
                prints[photos[oldest].id] = nil
                oldest += 1
            }
            guard let print = prints[photos[current].id] else { continue }
            for earlier in oldest..<current where alike(print, prints[photos[earlier].id]) {
                links.join(earlier, current)
            }
        }

        var groups: [LookAlikeGroup] = []
        for members in links.groups() where members.count > 1 {
            if Task.isCancelled { return [] }
            let files = members.map { photos[$0] }
            groups.append(LookAlikeGroup(id: files.map { String($0.id) }.joined(separator: "-"), files: files,
                                         best: await best(of: files)))
        }
        return groups.sorted { Self.taken($0.files.last!) > Self.taken($1.files.last!) }
    }

    private func alike(_ a: Data?, _ b: Data?) -> Bool {
        guard let a, let b, let distance = comparer.distance(a, b) else { return false }
        return distance <= threshold
    }

    /// The highest-scored photo; without scores (or on a tie), the largest. Scores are kept in the index, so a
    /// photo is scored once; while the power rules say wait, photos without one aren't scored yet.
    private func best(of files: [IndexedFile]) async -> IndexedFile.ID {
        let stored = await index.scores(ids: files.map(\.id))
        var ranked: [(file: IndexedFile, score: Float)] = []
        for file in files {
            var score = stored[file.id]
            if score == nil, !power.shouldPause, let fresh = await scorer.score(imageAt: file.path) {
                try? await index.storeScore(for: file, score: fresh)
                score = fresh
            }
            ranked.append((file, score ?? -.infinity))
        }
        return ranked.max { a, b in a.score != b.score ? a.score < b.score : a.file.bytes < b.file.bytes }!.file.id
    }

    static func taken(_ file: IndexedFile) -> Date { file.created ?? file.added }

    /// Photos in the same folder whose names say they're the same picture: equal stems (a HEIC/JPEG pair
    /// counts as alike without looking), or one stem plus a suffix after a space or punctuation, like
    /// "IMG_2041 edited" or "IMG_2041-2". Photos exports an edited IMG_2041 as IMG_E2041.
    static func namePairs(_ photos: [IndexedFile]) -> [(Int, Int, Bool)] {
        var pairs: [(Int, Int, Bool)] = []
        let byFolder = Dictionary(grouping: photos.indices, by: { photos[$0].parent })
        for indices in byFolder.values where indices.count > 1 {
            let named = indices.map { (index: $0, stem: stem(photos[$0].name)) }.sorted { $0.stem < $1.stem }
            for (position, first) in named.enumerated() {
                for second in named[(position + 1)...] {
                    guard second.stem.hasPrefix(first.stem) else { break }
                    if second.stem == first.stem {
                        let extensions = Set([photos[first.index].fileExtension, photos[second.index].fileExtension])
                        let pair = extensions.contains("heic") && !extensions.isDisjoint(with: ["jpg", "jpeg"])
                        pairs.append((first.index, second.index, pair))
                    } else if first.stem.count >= 4,
                              let next = second.stem.dropFirst(first.stem.count).first, !next.isLetter, !next.isNumber {
                        pairs.append((first.index, second.index, false))
                    }
                }
            }
        }
        return pairs
    }

    static func stem(_ name: String) -> String {
        (name as NSString).deletingPathExtension.lowercased()
            .replacingOccurrences(of: #"_e(?=\d+$)"#, with: "_", options: .regularExpression)
    }
}

/// Which photos belong together, joined pair by pair.
private struct Links {
    private var parent: [Int]

    init(count: Int) { parent = Array(0..<count) }

    mutating func root(_ item: Int) -> Int {
        var item = item
        while parent[item] != item {
            parent[item] = parent[parent[item]]
            item = parent[item]
        }
        return item
    }

    mutating func join(_ a: Int, _ b: Int) {
        let (rootA, rootB) = (root(a), root(b))
        if rootA != rootB { parent[max(rootA, rootB)] = min(rootA, rootB) }
    }

    /// Each group's members in order.
    mutating func groups() -> [[Int]] {
        var groups: [Int: [Int]] = [:]
        for item in parent.indices { groups[root(item), default: []].append(item) }
        return groups.keys.sorted().compactMap { groups[$0] }
    }
}
