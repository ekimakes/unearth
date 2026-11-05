import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UnearthCore

// Developer tool: run Unearth's engine from Terminal and print what it finds.
//   unearth-scan scan <root> [--display-root <path>]
//   unearth-scan breakdown [<root>] [--display-root /] [--home <path>]   (default root: the Data volume)
//   unearth-scan plan <root> [--display-root /] [--home <path>]          (lists cleanup items; runs read-only tool checks)
//   unearth-scan make-demo <dir>                                         (a small fake disk for screenshots)

let arguments = Array(CommandLine.arguments.dropFirst())

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func usage() -> Never {
    print("usage: unearth-scan scan <root> [--display-root <path>]")
    print("       unearth-scan breakdown [<root>] [--display-root /] [--home <path>]")
    print("       unearth-scan plan <root> [--display-root /] [--home <path>]")
    exit(2)
}

/// Builds `<dir>/Users/demo/…` and friends: one small file in every place Unearth knows about.
func makeDemo(at root: String) throws {
    let mb = 1_000_000
    let old = Date().addingTimeInterval(-40 * 86_400)
    let files: [(String, Int, Date?)] = [
        ("Users/demo/Documents/Taxes 2025.pdf", 2 * mb, nil),
        ("Users/demo/Documents/Thesis/draft.docx", 1 * mb, nil),
        ("Users/demo/Desktop/Screen Recording 2026-01-10.mov", 8 * mb, nil),
        ("Users/demo/Pictures/Photos Library.photoslibrary/database/Photos.sqlite", 6 * mb, nil),
        ("Users/demo/Movies/Vacation.mp4", 60 * mb, old),
        ("Users/demo/Downloads/Figma-installer.dmg", 4 * mb, nil),
        ("Users/demo/Downloads/fonts.zip", 2 * mb, nil),
        ("Users/demo/Downloads/fonts/Inter.ttf", 1 * mb, nil),
        ("Users/demo/Library/Caches/com.spotify.client/Data/cache.bin", 5 * mb, nil),
        ("Users/demo/Library/Caches/com.tinyspeck.slackmacgap/Cache.db", 3 * mb, nil),
        ("Users/demo/Library/Caches/com.apple.Music/Cache.db", 2 * mb, nil),
        ("Users/demo/Library/Caches/Google/Chrome/Default/Cache/data_1", 4 * mb, nil),
        ("Users/demo/Library/Logs/DiagnosticReports/Example.crash", 2 * mb, nil),
        ("Users/demo/Library/Application Support/Slack/Cache/data_0", 2 * mb, nil),
        ("Users/demo/Library/Application Support/Code/CachedData/x.bin", 2 * mb, nil),
        ("Users/demo/Library/Developer/Xcode/DerivedData/Unearth-abcdefghijklmnopqrstuvwxyzab/Build/x", 12 * mb, nil),
        ("Users/demo/Library/Developer/Xcode/iOS DeviceSupport/iPhone15,2 18.1 (22B83)/Symbols/x", 6 * mb, nil),
        ("Users/demo/Library/Developer/CoreSimulator/Caches/dyld/x", 3 * mb, nil),
        ("Users/demo/.npm/_cacache/content-v2/x", 4 * mb, nil),
        ("Users/demo/.cache/huggingface/hub/models--openai--whisper-small/blobs/x", 9 * mb, nil),
        ("Users/demo/Code/website/package.json", 1_000, old),
        ("Users/demo/Code/website/src/index.js", 20_000, old),
        ("Users/demo/Code/website/node_modules/react/index.js", 7 * mb, old),
        ("Users/demo/Library/Application Support/MobileSync/Backup/00008110-DEMO/Manifest.db", 10 * mb, nil),
        ("Users/demo/.Trash/old-presentation.key", 3 * mb, nil),
        ("Users/demo/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", 8 * mb, nil),
        ("Users/demo/Library/Preferences/com.example.plist", 50_000, nil),
        ("Library/Developer/CoreSimulator/Images/runtime.dmg", 5 * mb, nil),
        ("private/var/folders/xx/demo/T/leftover.tmp", 1 * mb, old),
    ]
    let manager = FileManager.default
    for (relative, size, modified) in files {
        let path = Paths.join(root, relative)
        try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard manager.createFile(atPath: path, contents: filler(size, for: relative)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if let modified { try manager.setAttributes([.modificationDate: modified], ofItemAtPath: path) }
    }
    let info = try PropertyListSerialization.data(
        fromPropertyList: ["Device Name": "Demo iPhone", "Last Backup Date": Date().addingTimeInterval(-90 * 86_400)],
        format: .xml, options: 0)
    try info.write(to: URL(fileURLWithPath: Paths.join(root, "Users/demo/Library/Application Support/MobileSync/Backup/00008110-DEMO/Info.plist")))
    try makeDemoLibrary(home: Paths.join(root, "Users/demo"))
    try makeDemoApps(root: root, home: Paths.join(root, "Users/demo"))
    print("Demo disk ready at \(root). Home: /Users/demo")
}

/// Real pictures (some with text to read), and downloads that remember where they came from.
func makeDemoLibrary(home: String) throws {
    let screenshots: [(String, [String])] = [
        ("Desktop/Screenshot 2026-11-02 at 16.40.05.png", ["Flight AMS to LIS", "Boarding 18:40  Gate D7"]),
        ("Desktop/Screenshot 2026-11-03 at 10.12.33.png", ["Order confirmation", "UNEARTH INVOICE 1042", "Total 99.00 EUR"]),
    ]
    for (relative, lines) in screenshots {
        let path = Paths.join(home, relative)
        try writeImage(path, colors: (0xFFFFFF, 0xF2F2F2), lines: lines)
        try setMetadata(path, "kMDItemIsScreenCapture", true)
    }
    let pictures: [(String, (UInt32, UInt32), [String])] = [
        ("Pictures/IMG_2041.jpg", (0xF7B267, 0xF25C54), []),
        ("Pictures/IMG_2042.jpg", (0x4D96FF, 0x6BCB77), []),
        ("Pictures/Team offsite.jpg", (0x6BCB77, 0x2E8B57), []),
        ("Pictures/Logo final v3.png", (0xE8772E, 0xF4A261), []),
        ("Pictures/Receipt scan.jpg", (0xFFFDF5, 0xF1EAD8), ["CORNER CAFE", "2 x Flat white   7.00", "RECEIPT TOTAL   7.00"]),
    ]
    // Taken days apart, as photos usually are; only the demo's burst is seconds apart.
    for (index, (relative, colors, lines)) in pictures.enumerated() {
        let path = Paths.join(home, relative)
        try writeImage(path, colors: colors, lines: lines)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-Double(40 - index * 7) * 86_400)],
                                              ofItemAtPath: path)
    }
    let downloads: [(String, Int, [String])] = [
        ("Downloads/Invoice-1042.pdf", 220_000, ["https://files.oaiusercontent.com/file-7Qx/Invoice-1042.pdf", "https://chatgpt.com/"]),
        ("Downloads/Q3 report.pdf", 1_400_000, ["https://mail-attachment.googleusercontent.com/attachment/u/0/x", "https://mail.google.com/"]),
        ("Downloads/brand-assets.zip", 3_000_000, ["https://files.slack.com/files-pri/T01/brand-assets.zip", "https://app.slack.com/"]),
        ("Downloads/release-notes.md", 12_000, ["https://raw.githubusercontent.com/unearth/unearth/main/notes.md"]),
        ("Downloads/Trip budget.xlsx", 90_000, ["https://files.oaiusercontent.com/file-9Kp/Trip budget.xlsx", "https://chatgpt.com/"]),
        ("Downloads/Cover letter.docx", 40_000, ["https://files.oaiusercontent.com/file-2Lm/Cover letter.docx", "https://chatgpt.com/"]),
        ("Downloads/Standup notes.pdf", 300_000, ["https://files.slack.com/files-pri/T01/standup.pdf", "https://app.slack.com/"]),
        ("Downloads/Onboarding.pdf", 650_000, ["https://files.slack.com/files-pri/T01/onboarding.pdf", "https://app.slack.com/"]),
    ]
    for (relative, size, whereFroms) in downloads {
        let path = Paths.join(home, relative)
        guard FileManager.default.createFile(atPath: path, contents: filler(size, for: relative)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try setMetadata(path, "kMDItemWhereFroms", whereFroms)
    }
    let shared = Paths.join(home, "Downloads/shared-on-x.jpg")
    try writeImage(shared, colors: (0x222831, 0x393E46), lines: ["Ship it"])
    try setMetadata(shared, "kMDItemWhereFroms", ["https://pbs.twimg.com/media/F1.jpg", "https://x.com/"])
    for relative in ["Music/Demo track.m4a", "Music/Voice memo 12.m4a"] {
        let path = Paths.join(home, relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: filler(800_000, for: relative))
    }
    try makeDemoCollections(home: home)
}

/// Something for every clean-up collection: copies, look-alike photos, old screenshots and old downloads.
func makeDemoCollections(home: String) throws {
    let manager = FileManager.default
    let day: TimeInterval = 86_400
    // Exact copies, written byte for byte (a Finder copy would be an APFS clone, which frees nothing).
    for (source, copy) in [("Pictures/IMG_2041.jpg", "Downloads/IMG_2041.jpg"), ("Downloads/Q3 report.pdf", "Documents/Q3 report.pdf")] {
        let data = try Data(contentsOf: URL(fileURLWithPath: Paths.join(home, source)))
        try data.write(to: URL(fileURLWithPath: Paths.join(home, copy)))
    }
    // A burst taken seconds apart, an edit saved later, and a photo kept as both HEIC and JPEG.
    let taken = Date().addingTimeInterval(-20 * day)
    for index in 0..<3 {
        let path = Paths.join(home, "Pictures/Beach/IMG_300\(index + 1).jpg")
        try writeImage(path, colors: (0x8ECAE6, UInt32(0x219EBC + index * 0x020202)), lines: [])
        try manager.setAttributes([.creationDate: taken.addingTimeInterval(Double(index) * 2)], ofItemAtPath: path)
    }
    let edited = Paths.join(home, "Pictures/IMG_2042 edited.jpg")
    try writeImage(edited, colors: (0x5AA0FF, 0x74D282), lines: [])
    try manager.setAttributes([.creationDate: Date().addingTimeInterval(-2 * day)], ofItemAtPath: edited)
    for type in ["heic", "jpg"] {
        let path = Paths.join(home, "Pictures/IMG_4100.\(type)")
        try writeImage(path, colors: (0xFFB4A2, 0xE5989B), lines: [])
        try manager.setAttributes([.creationDate: Date().addingTimeInterval(-8 * day)], ofItemAtPath: path)
    }
    // Screenshots taken months ago.
    let oldShots = [("Screenshot 2026-07-12 at 14.02.11.png", 115.0, ["Meeting notes", "Q2 planning"]),
                    ("Screenshot 2026-08-01 at 09.15.00.png", 95.0, ["Wi-Fi password", "Guest network"])]
    for (name, daysAgo, lines) in oldShots {
        let path = Paths.join(home, "Desktop/" + name)
        try writeImage(path, colors: (0xFFFFFF, 0xEDEDED), lines: lines)
        try setMetadata(path, "kMDItemIsScreenCapture", true)
        try manager.setAttributes([.creationDate: Date().addingTimeInterval(-daysAgo * day)], ofItemAtPath: path)
    }
    // Downloads nobody has opened in four months.
    for (name, size) in [("old-flyer.pdf", 1_800_000), ("meeting-recording.m4a", 2_400_000)] {
        let path = Paths.join(home, "Downloads/" + name)
        guard manager.createFile(atPath: path, contents: filler(size, for: name)) else { throw CocoaError(.fileWriteUnknown) }
        try manager.setAttributes([.modificationDate: Date().addingTimeInterval(-120 * day)], ofItemAtPath: path)
    }
}

/// An app nobody has opened for months, with what it keeps in the home folder, and one inside a vendor's folder.
func makeDemoApps(root: String, home: String) throws {
    let manager = FileManager.default
    // Example.app sits in ~/Applications, where an app the user installed can be; the vendor's app in /Applications.
    let apps = [("Users/demo/Applications/Example.app", "com.example.Example", 200.0),
                ("Applications/Maxon Demo 2026/Demo 4D.app", "net.maxon.demo4d", 300.0)]
    for (relative, id, daysAgo) in apps {
        let app = Paths.join(root, relative)
        try manager.createDirectory(atPath: Paths.join(app, "Contents/MacOS"), withIntermediateDirectories: true)
        let binary = Paths.join(app, "Contents/MacOS/" + ((relative as NSString).lastPathComponent as NSString).deletingPathExtension)
        if !manager.fileExists(atPath: binary) {
            guard manager.createFile(atPath: binary, contents: filler(2_000_000, for: id)) else { throw CocoaError(.fileWriteUnknown) }
        }
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": id], format: .xml, options: 0)
        try info.write(to: URL(fileURLWithPath: Paths.join(app, "Contents/Info.plist")))
        // The demo disk has no Spotlight; when an app last changed stands in for when it was opened.
        try manager.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: app)
    }
    let leftovers = [
        ("Library/Application Support/com.example.Example/state.db", 1_500_000), ("Library/Caches/com.example.Example/cache.bin", 2_500_000),
        ("Library/Preferences/com.example.Example.plist", 4_000),
    ]
    for (relative, size) in leftovers {
        let path = Paths.join(home, relative)
        try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard manager.createFile(atPath: path, contents: filler(size, for: relative)) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Made-up file contents that start with `name`, so no two demo files are copies of each other by accident.
func filler(_ size: Int, for name: String) -> Data {
    var data = Data(repeating: 0xAB, count: size)
    let label = Data(name.utf8)
    data.replaceSubrange(0..<min(size, label.count), with: label.prefix(size))
    return data
}

/// A 1200×800 picture: a diagonal gradient, with lines of dark text when given.
func writeImage(_ path: String, colors: (UInt32, UInt32), lines: [String]) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let width = 1_200, height = 800
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    func color(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: 1)
    }
    let gradient = CGGradient(colorsSpace: space, colors: [color(colors.0), color(colors.1)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil)
    for (index, line) in lines.enumerated() {
        let text = NSAttributedString(string: line, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(0x1D1D1F),
        ])
        context.textPosition = CGPoint(x: 80, y: height - 180 - index * 110)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
    let type = path.hasSuffix(".png") ? UTType.png : path.hasSuffix(".heic") ? UTType.heic : UTType.jpeg
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, type.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

/// Spotlight metadata the way macOS stores it on a file: a binary property list in an extended attribute.
func setMetadata(_ path: String, _ name: String, _ value: Any) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    let status = data.withUnsafeBytes { setxattr(path, "com.apple.metadata:" + name, $0.baseAddress, data.count, 0, 0) }
    guard status == 0 else { throw CocoaError(.fileWriteUnknown) }
}

/// The CLI has no AppKit: no app names, nothing counts as running.
struct NoApps: AppNameResolving {
    func appName(forBundleID bundleID: String) -> String? { nil }
    func isRunning(_ owner: String) -> Bool { false }
}

func printPlan(_ plan: CleanupPlan) {
    for section in CleanupSection.allCases {
        let items = plan.items(in: section)
        guard !items.isEmpty else { continue }
        print("\(section.rawValue):")
        for item in items {
            let size = ByteFormatting.string(item.bytes).padding(toLength: 12, withPad: " ", startingAt: 0)
            let blocked = item.blockedReason.map { " [blocked: \($0)]" } ?? ""
            print("  \(item.safety.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(size) \(item.group) › \(item.title)\(blocked)")
        }
    }
    print("Safe to free by default: \(ByteFormatting.string(plan.totalBytes(of: plan.defaultSelection())))")
}

func printBreakdown(_ breakdown: StorageBreakdown, tree: ScanTree) {
    func line(_ label: String, _ bytes: Int64) -> String {
        "  \(ByteFormatting.string(bytes).padding(toLength: 12, withPad: " ", startingAt: 0)) \(label)"
    }
    print("Used \(ByteFormatting.string(breakdown.used)) of \(ByteFormatting.string(breakdown.total)), free \(ByteFormatting.string(breakdown.free)), purgeable \(ByteFormatting.string(breakdown.purgeable))")
    for (category, bytes) in breakdown.segments.sorted(by: { $0.value > $1.value }) { print(line(category.rawValue, bytes)) }
    print("System Data:")
    for (bucket, bytes) in breakdown.systemData.sorted(by: { $0.value > $1.value }) where bytes > 0 {
        print(line(bucket.rawValue, bytes))
        for contributor in breakdown.bucketContributors[bucket, default: []].prefix(3) {
            print("      " + line(tree.path(of: contributor.node), contributor.bytes))
        }
    }
    if breakdown.overcount > 0 { print("Overcount: \(ByteFormatting.string(breakdown.overcount))") }
}

func printSummary(_ tree: ScanTree) {
    let root = tree.node(tree.rootID)
    let stats = tree.stats
    print("Scanned \(tree.path(of: tree.rootID)) in \(stats.elapsed.formatted(.units(allowed: [.seconds, .milliseconds])))")
    print("  \(stats.files) files, \(stats.directories) folders, \(ByteFormatting.string(root.totalBytes))")
    print("  \(stats.inaccessibleDirectories) unreadable folders, \(stats.mountPointsSkipped) mount points skipped, \(stats.cloudOnlyFiles) cloud-only files")
    print("Largest folders:")
    for id in root.children.prefix(20) {
        let node = tree.node(id)
        print("  \(ByteFormatting.string(node.totalBytes).padding(toLength: 12, withPad: " ", startingAt: 0)) \(tree.path(of: id))")
    }
    if !tree.bigFiles.isEmpty {
        print("Largest files:")
        for file in tree.bigFiles.prefix(10) {
            print("  \(ByteFormatting.string(file.bytes).padding(toLength: 12, withPad: " ", startingAt: 0)) \(file.path)")
        }
    }
}

switch arguments.first {
case "scan":
    guard arguments.count >= 2 else { usage() }
    let options = ScanOptions(rootPath: arguments[1], displayRoot: value(after: "--display-root"))
    printSummary(try await DiskScanner().scan(options))
case "breakdown":
    let root = arguments.count >= 2 && !arguments[1].hasPrefix("--") ? arguments[1] : "/System/Volumes/Data"
    let options = ScanOptions(rootPath: root, displayRoot: value(after: "--display-root") ?? "/")
    async let volumes = VolumeInventory.load(runner: ProcessCommandRunner())
    let tree = try await DiskScanner().scan(options)
    printSummary(tree)
    printBreakdown(
        StorageBreakdown.compute(tree: tree, volumes: try await volumes, homePath: value(after: "--home") ?? NSHomeDirectory()),
        tree: tree)
case "plan":
    guard arguments.count >= 2 else { usage() }
    let tree = try await DiskScanner().scan(ScanOptions(rootPath: arguments[1], displayRoot: value(after: "--display-root") ?? "/"))
    let context = DetectionContext(
        tree: tree, homePath: value(after: "--home") ?? NSHomeDirectory(), now: Date(), settings: CleanupSettings(),
        apps: NoApps(), runner: ProcessCommandRunner(), knowledgeBase: try KnowledgeBase.bundled())
    printPlan(await CleanupPlanner.standard().plan(context))
case "make-demo":
    guard arguments.count >= 2 else { usage() }
    try makeDemo(at: arguments[1])
default:
    usage()
}
