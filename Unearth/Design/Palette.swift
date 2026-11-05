import AppKit
import SwiftUI
import UnearthCore

/// The Gallery look's colors. Each has a light and a dark value and follows the window's appearance.
extension Color {
    /// Unearth orange: only for a screen's main action and the "safe to free" figure.
    static let unearth = Color(hex: 0xE8772E)

    /// The window's background, behind the cards.
    static let canvas = dynamic(light: 0xF6F7F9, dark: 0x16181D)
    /// Cards and tiles.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1F2228)
    /// The thin line around a card.
    static let hairline = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.08) : NSColor(hex: 0xE8EAEF)
    })
    /// The sidebar, light mode only: in dark mode the system's sidebar material shows through.
    static let sidebarFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? .clear : NSColor(hex: 0xECEEF2)
    })
    static let ink = dynamic(light: 0x15171C, dark: 0xECEDF0)
    static let secondaryInk = dynamic(light: 0x6B7280, dark: 0x9AA0AB)
    /// Free space in the storage band.
    static let freeSpace = dynamic(light: 0xE4E7EC, dark: 0x3A3F4A)
    /// The tinted card that leads "Worth a look": the safe-to-free plan.
    static let hotFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0xE8772E).withAlphaComponent(0.14) : NSColor(hex: 0xFFF4EC)
    })
    static let hotLine = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0xE8772E).withAlphaComponent(0.35) : NSColor(hex: 0xF7D4BC)
    })

    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(hex: dark) : NSColor(hex: light) })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension FileKind {
    /// One color per kind, used everywhere: sidebar icons, tiles, chips and search badges.
    var color: Color {
        switch self {
        case .image: Color(hex: 0x7A5AF8)
        case .video: Color(hex: 0x2E90FA)
        case .screenshot: Color(hex: 0x06AED4)
        case .document: Color(hex: 0x12B76A)
        case .audio: Color(hex: 0xEE46BC)
        case .archive: Color(hex: 0xF79009)
        case .app: Color(hex: 0x6172F3)
        case .other: Color(hex: 0x98A2B3)
        }
    }
}

extension StorageCategory {
    /// The storage band's colors, matched to the kinds of file each category mostly holds.
    var color: Color {
        switch self {
        case .apps: Color(hex: 0x6172F3)
        case .documents: Color(hex: 0x12B76A)
        case .photosVideos: Color(hex: 0x7A5AF8)
        case .iosBackups: Color(hex: 0xEE46BC)
        case .developer: Color(hex: 0x06AED4)
        case .systemData: Color(hex: 0x98A2B3)
        case .macOS: .dynamic(light: 0x344054, dark: 0x667085)
        case .other: Color(hex: 0xEAAA08)
        }
    }
}

extension Font {
    /// Sizes are the heart of the app: SF Pro Rounded, with figures that line up.
    static func size(_ points: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: points, weight: weight, design: .rounded).monospacedDigit()
    }
}
