import Foundation

/// Developer switches for running the app against a fake disk and capturing screenshots.
/// Release builds ignore them all.
///
/// They're Cocoa-style key/value arguments (`-UnearthDryRun YES`), read through UserDefaults.
/// macOS pairs every dashed argument with the one after it; a valueless flag would shift that
/// pairing and leave a path unpaired, which AppKit treats as a document to open — and SwiftUI
/// then skips creating the main window.
struct LaunchOptions {
    /// Scan this folder (shown as "/") instead of the startup disk.
    var scanRoot: String?
    /// Home folder as a display path, e.g. "/Users/demo".
    var home: String?
    /// Cleanups record what they would do and touch nothing.
    var dryRun = false
    var snapshotDirectory: String?
    var skipOnboarding = false
    var showOnboarding = false
    var autoCleanDefault = false
    /// With a snapshot directory: only check the timeline, on the real window as well, then quit.
    var timelineCheck = false
    /// With a snapshot directory: move every image to the Trash through the real window, then Undo, and quit.
    /// Refused unless the sample disk is on a volume of its own, so nothing reaches the real Trash.
    var trashCheck = false
    /// With a snapshot directory: write how soon the screens filled in after launch, and quit.
    var openCheck = false
    /// After each scan, write its numbers here as JSON (for checking a real-disk run).
    var reportFile: String?

    /// Only the command line counts: a value saved with `defaults write` would outlive the run it was for.
    static func parse(_ arguments: [String: Any] = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)) -> LaunchOptions {
        var options = LaunchOptions()
        #if DEBUG
        func text(_ key: String) -> String? { arguments[key] as? String }
        func flag(_ key: String) -> Bool { text(key).map { ($0 as NSString).boolValue } ?? false }
        options.scanRoot = text("UnearthScanRoot")
        options.home = text("UnearthHome")
        options.dryRun = flag("UnearthDryRun")
        options.snapshotDirectory = text("UnearthSnapshotDir")
        options.skipOnboarding = flag("UnearthSkipOnboarding")
        options.showOnboarding = flag("UnearthShowOnboarding")
        options.autoCleanDefault = flag("UnearthAutoCleanDefault")
        options.timelineCheck = flag("UnearthTimelineCheck")
        options.trashCheck = flag("UnearthTrashCheck")
        options.openCheck = flag("UnearthOpenCheck")
        options.reportFile = text("UnearthReportFile")
        #endif
        return options
    }
}
