import Foundation

/// One layer of the strata picture: a storage category, or free space as the sky.
public struct StrataLayer: Sendable, Equatable {
    /// Nil for free space.
    public let category: StorageCategory?
    public let bytes: Int64
    /// From 0 (the top of the picture) to 1 (the bottom); each layer starts where the one above ends.
    public let top: Double
    public let bottom: Double
}

/// The disk drawn as layers of earth: thickness follows size, with a floor so every label fits.
public enum StrataLayout {
    /// Top to bottom, under the sky.
    public static let order: [StorageCategory] = [.apps, .documents, .photosVideos, .iosBackups, .developer, .systemData, .macOS, .other]

    /// Layers for the categories that hold anything, free space first. Every layer gets at least
    /// `minimumShare` of the height; the rest is shared by size.
    public static func layers(segments: [StorageCategory: Int64], free: Int64, minimumShare: Double = 0.05) -> [StrataLayer] {
        var entries: [(category: StorageCategory?, bytes: Int64)] = free > 0 ? [(nil, free)] : []
        entries += order.compactMap { category in segments[category].flatMap { $0 > 0 ? (category, $0) : nil } }
        let heights = shares(entries.map { Double($0.bytes) }, minimum: minimumShare)
        var top = 0.0
        return entries.indices.map { index in
            let bottom = index == entries.count - 1 ? 1 : top + heights[index]
            defer { top = bottom }
            return StrataLayer(category: entries[index].category, bytes: entries[index].bytes, top: top, bottom: bottom)
        }
    }

    /// Offsets along a layer's top edge, a fraction of the picture's height. Seeded by the category, so the
    /// same disk always draws the same picture.
    public static func wave(for layer: StrataLayer, samples: Int = 24, amplitude: Double = 0.012) -> [Double] {
        var seed = UInt64(layer.category.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0) &* 0x9E37_79B9_7F4A_7C15 &+ 17
        let phases = (0..<3).map { _ in random(&seed) * 2 * .pi }
        let frequencies = [1.0, 2.0 + random(&seed), 3.5 + random(&seed)]
        let weights = [0.5, 0.3, 0.2]
        return (0..<samples).map { sample in
            let x = Double(sample) / Double(max(samples - 1, 1))
            let value = (0..<3).reduce(0.0) { $0 + weights[$1] * sin(2 * .pi * frequencies[$1] * x + phases[$1]) }
            return value * amplitude
        }
    }

    /// Shares of 1 in proportion to `sizes`, none below `minimum` (all equal when that's impossible).
    static func shares(_ sizes: [Double], minimum: Double) -> [Double] {
        guard !sizes.isEmpty else { return [] }
        guard minimum * Double(sizes.count) < 1 else { return sizes.map { _ in 1 / Double(sizes.count) } }
        var floored = Set<Int>()
        while true {
            let rest = sizes.indices.filter { !floored.contains($0) }
            let left = 1 - minimum * Double(floored.count)
            let total = rest.reduce(0) { $0 + sizes[$1] }
            var shares = sizes.indices.map { floored.contains($0) ? minimum : 0 }
            for index in rest { shares[index] = total > 0 ? left * sizes[index] / total : left / Double(rest.count) }
            let tooThin = rest.filter { shares[$0] < minimum }
            if tooThin.isEmpty { return shares }
            floored.formUnion(tooThin)
        }
    }

    /// A small deterministic generator (SplitMix64), from 0 up to 1.
    private static func random(_ state: inout UInt64) -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / Double(UInt64(1) << 53)
    }
}
