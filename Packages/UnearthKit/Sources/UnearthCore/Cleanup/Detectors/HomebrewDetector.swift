import Foundation

/// Old package versions and downloads Homebrew keeps. Only `brew cleanup` removes them correctly.
public struct HomebrewDetector: CleanupDetector {
    /// Keeps Homebrew from going online while Unearth asks it questions.
    public static let environment = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1"]

    private static let explanation = Explanation(
        what: "Older versions of Homebrew packages and installers Homebrew downloaded.",
        regrows: "Yes, as you upgrade packages.",
        safeToDelete: "Yes. Homebrew keeps the versions you're using.")

    private let brewPaths: [String]

    public init(brewPaths: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) {
        self.brewPaths = brewPaths
    }

    public func detect(in context: DetectionContext) async -> [CleanupItem] {
        guard let brew = brewPaths.first(where: FileManager.default.isExecutableFile(atPath:)),
              Self.hasCachedPackageLists(brew: brew, context),
              let result = try? await context.runner.run(brew, ["cleanup", "--prune=all", "--dry-run"], environment: Self.environment),
              result.exitCode == 0,
              let bytes = Self.parseFreedBytes(String(decoding: result.stdout, as: UTF8.self)), bytes > 0 else { return [] }
        return [CleanupItem(
            ruleID: "homebrew-cleanup", section: .developer, group: "Package manager caches",
            title: "Old Homebrew versions and downloads", subtitle: nil, paths: [], bytes: bytes, safety: .safe,
            action: .tool(ToolCommand(toolName: "Homebrew", executable: brew, arguments: ["cleanup", "--prune=all"])),
            explanation: Self.explanation, owner: nil, blockedReason: nil)]
    }

    /// Any brew command first downloads the package lists it's missing, and Unearth never goes online.
    /// Cleanup reads the cask list only when casks are installed.
    static func hasCachedPackageLists(brew: String, _ context: DetectionContext) -> Bool {
        let lists = context.tree.realPath(forDisplayPath: Paths.join(context.homePath, "Library/Caches/Homebrew/api"))
        let prefix = ((brew as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let casks = (try? FileManager.default.contentsOfDirectory(atPath: Paths.join(prefix, "Caskroom"))) ?? []
        let needed = ["formula.jws.json"] + (casks.contains { !$0.hasPrefix(".") } ? ["cask.jws.json"] : [])
        return needed.allSatisfy { FileManager.default.fileExists(atPath: Paths.join(lists, $0)) }
    }

    /// Reads "would free approximately 1.2GB". Homebrew's units are 1024-based.
    static func parseFreedBytes(_ output: String) -> Int64? {
        guard let match = output.firstMatch(of: #/free approximately ([0-9.]+)\s*(TB|GB|MB|KB|B)/#),
              let value = Double(match.1) else { return nil }
        let multiplier: Double = switch match.2 {
        case "TB": 1_099_511_627_776
        case "GB": 1_073_741_824
        case "MB": 1_048_576
        case "KB": 1_024
        default: 1
        }
        return Int64(value * multiplier)
    }
}
