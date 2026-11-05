import Foundation

/// Simulators that can't run anymore and simulator runtimes, both removed through `simctl`.
public struct SimulatorDetector: CleanupDetector {
    private static let unavailableExplanation = Explanation(
        what: "Simulators for system versions you no longer have installed. They can't run anymore.",
        regrows: "No.",
        safeToDelete: "Yes. They can't be used without their missing system version.")
    private static let runtimeExplanation = Explanation(
        what: "A full copy of iOS (or another Apple system) that Xcode uses to run simulators.",
        regrows: "Only if you download that version again in Xcode.",
        safeToDelete: "Yes, if you don't test on this version anymore. Xcode can download it again.")

    public init() {}

    public func detect(in context: DetectionContext) async -> [CleanupItem] {
        // Calling xcrun on a Mac without developer tools pops up an installer, so ask xcode-select first.
        guard let select = try? await context.runner.run("/usr/bin/xcode-select", ["-p"], environment: [:]),
              select.exitCode == 0 else { return [] }
        return await unavailableDevices(context) + runtimes(context)
    }

    private func unavailableDevices(_ context: DetectionContext) async -> [CleanupItem] {
        guard let json = await xcrunJSON(["simctl", "list", "devices", "unavailable", "-j"], context),
              let devices = json["devices"] as? [String: [[String: Any]]] else { return [] }
        let udids = devices.values.flatMap { $0 }.compactMap { $0["udid"] as? String }
        guard !udids.isEmpty else { return [] }
        let folder = Paths.join(context.homePath, "Library/Developer/CoreSimulator/Devices")
        let bytes = udids.reduce(Int64(0)) { $0 + (context.tree.node(atPath: Paths.join(folder, $1))?.totalBytes ?? 0) }
        return [CleanupItem(
            ruleID: "simulators-unavailable", section: .developer, group: "Simulators",
            title: "Unavailable simulators (\(udids.count))", subtitle: nil, paths: [], bytes: bytes, safety: .safe,
            action: .tool(ToolCommand(toolName: "Xcode", executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"])),
            explanation: Self.unavailableExplanation, owner: nil, blockedReason: nil)]
    }

    private func runtimes(_ context: DetectionContext) async -> [CleanupItem] {
        guard let json = await xcrunJSON(["simctl", "runtime", "list", "-j"], context) else { return [] }
        let dates = ISO8601DateFormatter()
        let deletable = json.values.compactMap { $0 as? [String: Any] }.filter { $0["deletable"] as? Bool == true }
        let name = { (runtime: [String: Any]) in
            "\(Self.platformName(runtime["platformIdentifier"] as? String)) \(runtime["version"] as? String ?? "")"
        }
        // A beta and a release of one version look the same by name; the build tells them apart.
        let names = deletable.map(name)
        return deletable
            .compactMap { runtime -> CleanupItem? in
                guard let identifier = runtime["identifier"] as? String else { return nil }
                let lastUsed = (runtime["lastUsedAt"] as? String).flatMap(dates.date(from:))
                let build = (runtime["build"] as? String).map { " (\($0))" } ?? ""
                return CleanupItem(
                    ruleID: "simulator-runtime", section: .developer, group: "Simulators",
                    title: "\(name(runtime)) simulator runtime" + (names.filter { $0 == name(runtime) }.count > 1 ? build : ""),
                    subtitle: lastUsed.map { "Last used \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Never used",
                    paths: [], bytes: (runtime["sizeBytes"] as? NSNumber)?.int64Value ?? 0, safety: .review,
                    action: .tool(ToolCommand(toolName: "Xcode", executable: "/usr/bin/xcrun",
                                              arguments: ["simctl", "runtime", "delete", identifier])),
                    explanation: Self.runtimeExplanation, owner: nil, blockedReason: nil)
            }
            .sorted { $0.bytes > $1.bytes }
    }

    private func xcrunJSON(_ arguments: [String], _ context: DetectionContext) async -> [String: Any]? {
        guard let result = try? await context.runner.run("/usr/bin/xcrun", arguments, environment: [:]),
              result.exitCode == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
    }

    private static func platformName(_ identifier: String?) -> String {
        switch identifier {
        case "com.apple.platform.watchsimulator": "watchOS"
        case "com.apple.platform.appletvsimulator": "tvOS"
        case "com.apple.platform.xrsimulator": "visionOS"
        default: "iOS"
        }
    }
}
