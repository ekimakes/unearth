import Foundation
import Testing
@testable import UnearthCore

struct StrataTests {
    static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_1 }

    static func isWhole(_ layers: [StrataLayer]) -> Bool {
        guard let first = layers.first, let last = layers.last, near(first.top, 0), near(last.bottom, 1) else { return false }
        return zip(layers, layers.dropFirst()).allSatisfy { near($0.bottom, $1.top) }
    }

    @Test func thicknessFollowsSize() {
        let layers = StrataLayout.layers(segments: [.apps: 100, .documents: 300], free: 600)
        #expect(layers.map(\.category) == [nil, .apps, .documents])
        #expect(layers.map(\.bytes) == [600, 100, 300])
        #expect(Self.near(layers[0].bottom, 0.6) && Self.near(layers[1].bottom, 0.7))
        #expect(Self.isWhole(layers))
    }

    @Test func extremeDistributionsStayReadable() {
        let lopsided = StrataLayout.layers(segments: [.systemData: 99_000_000_000, .apps: 1, .documents: 0], free: 0)
        let crowded = StrataLayout.layers(
            segments: Dictionary(uniqueKeysWithValues: StrataLayout.order.map { ($0, $0 == .systemData ? 900_000_000_000 : 1) }),
            free: 3)
        for layers in [lopsided, crowded] {
            #expect(Self.isWhole(layers))
            #expect(layers.allSatisfy { $0.bottom - $0.top >= 0.05 - 0.000_1 && $0.top >= 0 && $0.bottom <= 1 })
        }
        #expect(lopsided.map(\.category) == [.apps, .systemData])
        #expect(crowded.count == 9)
        #expect(crowded.first { $0.category == .systemData }.map { $0.bottom - $0.top }.map { $0 > 0.5 } == true)
    }

    @Test func wavesAreStableForTheSameNumbers() {
        let layers = StrataLayout.layers(segments: [.apps: 100, .documents: 300], free: 600)
        let apps = StrataLayout.wave(for: layers[1])
        #expect(apps == StrataLayout.wave(for: layers[1]))
        #expect(apps != StrataLayout.wave(for: layers[2]))
        #expect(apps.count == 24)
        #expect(apps.allSatisfy { abs($0) <= 0.012 })
        #expect(apps.contains { abs($0) > 0.001 })
    }

    @Test func zeroByteCategoriesAreLeftOut() {
        let layers = StrataLayout.layers(segments: [.apps: 5, .iosBackups: 0, .other: 0, .macOS: 7], free: 0)
        #expect(layers.map(\.category) == [.apps, .macOS])
        #expect(StrataLayout.layers(segments: [:], free: 0).isEmpty)
    }
}
