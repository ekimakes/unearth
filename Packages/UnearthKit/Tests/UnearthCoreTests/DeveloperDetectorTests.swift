import Foundation
import Testing
@testable import UnearthCore

struct InactiveProjectsDetectorTests {
    static let old = Date().addingTimeInterval(-40 * 86_400)

    @Test func offersArtifactsOfOldProjects() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/Code/shop/package.json", bytes: 100, modified: Self.old)
        try home.file("/Users/u/Code/shop/src/index.js", bytes: 100, modified: Self.old)
        try home.file("/Users/u/Code/shop/node_modules/react/index.js", bytes: 2_000_000, modified: Self.old)
        try home.file("/Users/u/Code/engine/Cargo.toml", bytes: 100, modified: Self.old)
        try home.file("/Users/u/Code/engine/target/debug/engine", bytes: 3_000_000, modified: Self.old)
        let tree = try await home.scan()
        let items = await InactiveProjectsDetector().detect(in: .test(tree: tree, kb: try .test([])))
        #expect(Set(items.map(\.title)) == ["shop · node_modules", "engine · target"])
        #expect(Set(items.flatMap(\.paths)) == ["/Users/u/Code/shop/node_modules", "/Users/u/Code/engine/target"])
        #expect(items.allSatisfy { $0.safety == .review && $0.action == .trash && $0.section == .developer })
        #expect(items.allSatisfy { $0.group == "Build files in inactive projects" })
    }

    @Test func skipsActiveProjects() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/Code/shop/package.json", bytes: 100, modified: Self.old)
        try home.file("/Users/u/Code/shop/src/index.js", bytes: 100, modified: Date().addingTimeInterval(-86_400))
        try home.file("/Users/u/Code/shop/node_modules/react/index.js", bytes: 2_000_000, modified: Self.old)
        let tree = try await home.scan()
        #expect(await InactiveProjectsDetector().detect(in: .test(tree: tree, kb: try .test([]))).isEmpty)
    }

    @Test func ignoresNestedNodeModules() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/Code/shop/package.json", bytes: 100, modified: Self.old)
        try home.file("/Users/u/Code/shop/node_modules/lib/package.json", bytes: 100, modified: Self.old)
        try home.file("/Users/u/Code/shop/node_modules/lib/node_modules/dep/x.js", bytes: 2_000_000, modified: Self.old)
        let tree = try await home.scan()
        let items = await InactiveProjectsDetector().detect(in: .test(tree: tree, kb: try .test([])))
        #expect(items.flatMap(\.paths) == ["/Users/u/Code/shop/node_modules"])
    }

    @Test func ignoresLibraryAndHidden() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/Library/App/package.json", bytes: 100, modified: Self.old)
        try home.file("/Users/u/Library/App/node_modules/x/y.js", bytes: 2_000_000, modified: Self.old)
        try home.file("/Users/u/.config/tool/package.json", bytes: 100, modified: Self.old)
        try home.file("/Users/u/.config/tool/node_modules/x/y.js", bytes: 2_000_000, modified: Self.old)
        let tree = try await home.scan()
        #expect(await InactiveProjectsDetector().detect(in: .test(tree: tree, kb: try .test([]))).isEmpty)
    }
}

struct SimulatorDetectorTests {
    static func runner(xcodeSelectExit: Int32 = 0) throws -> FakeCommandRunner {
        FakeCommandRunner([
            "/usr/bin/xcode-select -p": CommandResult(
                exitCode: xcodeSelectExit, stdout: Data("/Applications/Xcode.app/Contents/Developer\n".utf8), stderr: Data()),
            "/usr/bin/xcrun simctl list devices unavailable -j": .success(try Fixtures.data("simctl-unavailable.json")),
            "/usr/bin/xcrun simctl runtime list -j": .success(try Fixtures.data("simctl-runtimes.json")),
        ])
    }

    static func tree() async throws -> (HomeFixture, ScanTree) {
        let home = try HomeFixture()
        try home.file("/Users/u/Library/Developer/CoreSimulator/Devices/AAAAAAAA-0000-4000-8000-000000000001/data/x", bytes: 2_000_000)
        try home.file("/Users/u/Library/Developer/CoreSimulator/Devices/AAAAAAAA-0000-4000-8000-000000000002/data/x", bytes: 3_000_000)
        return (home, try await home.scan())
    }

    @Test func doesNotRunXcrunWithoutDeveloperTools() async throws {
        let (home, tree) = try await Self.tree()
        defer { home.remove() }
        let runner = try Self.runner(xcodeSelectExit: 2)
        let items = await SimulatorDetector().detect(in: .test(tree: tree, kb: try .test([]), runner: runner))
        #expect(items.isEmpty)
        #expect(!runner.calls.contains { $0.executable == "/usr/bin/xcrun" })
    }

    @Test func offersUnavailableDevicesAsOneTool() async throws {
        let (home, tree) = try await Self.tree()
        defer { home.remove() }
        let items = await SimulatorDetector().detect(in: .test(tree: tree, kb: try .test([]), runner: try Self.runner()))
        let unavailable = try #require(items.first { $0.title == "Unavailable simulators (2)" })
        #expect(unavailable.safety == .safe)
        #expect(unavailable.bytes >= 5_000_000)
        #expect(unavailable.action == .tool(ToolCommand(
            toolName: "Xcode", executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"])))
    }

    @Test func offersDeletableRuntimes() async throws {
        let (home, tree) = try await Self.tree()
        defer { home.remove() }
        let items = await SimulatorDetector().detect(in: .test(tree: tree, kb: try .test([]), runner: try Self.runner()))
        let runtimes = items.filter { $0.title.hasSuffix("simulator runtime") }
        let runtime = try #require(runtimes.first)
        #expect(runtimes.count == 1)
        #expect(runtime.title == "iOS 17.5 simulator runtime")
        #expect(runtime.bytes == 7_516_192_768)
        #expect(runtime.safety == .review)
        #expect(runtime.subtitle?.hasPrefix("Last used ") == true)
        #expect(runtime.action == .tool(ToolCommand(
            toolName: "Xcode", executable: "/usr/bin/xcrun",
            arguments: ["simctl", "runtime", "delete", "11111111-1111-4111-8111-111111111111"])))
    }

    /// A beta and a release of one version are separate downloads; removing one must never remove the other.
    @Test func runtimesOfTheSameVersionStayApart() async throws {
        let (home, tree) = try await Self.tree()
        defer { home.remove() }
        let runtimes = #"""
        {"A": {"build": "23A5276f", "deletable": true, "identifier": "A", "version": "26.0", "sizeBytes": 7000000000,
               "platformIdentifier": "com.apple.platform.iphonesimulator"},
         "B": {"build": "23A343", "deletable": true, "identifier": "B", "version": "26.0", "sizeBytes": 8000000000,
               "platformIdentifier": "com.apple.platform.iphonesimulator"},
         "C": {"build": "21F79", "deletable": true, "identifier": "C", "version": "17.5", "sizeBytes": 6000000000,
               "platformIdentifier": "com.apple.platform.iphonesimulator"}}
        """#
        let runner = FakeCommandRunner([
            "/usr/bin/xcode-select -p": .success(Data("/Applications/Xcode.app/Contents/Developer\n".utf8)),
            "/usr/bin/xcrun simctl list devices unavailable -j": .success(Data(#"{"devices": {}}"#.utf8)),
            "/usr/bin/xcrun simctl runtime list -j": .success(Data(runtimes.utf8)),
        ])
        let items = await SimulatorDetector().detect(in: .test(tree: tree, kb: try .test([]), runner: runner))
        #expect(items.count == 3)
        #expect(Set(items.map(\.id)).count == 3)
        #expect(Set(items.map(\.title)) == [
            "iOS 26.0 simulator runtime (23A343)", "iOS 26.0 simulator runtime (23A5276f)", "iOS 17.5 simulator runtime",
        ])
    }
}

struct HomebrewDetectorTests {
    /// An executable stand-in for brew (never run: the fake runner answers), plus a home where Homebrew
    /// has cached its formula list, as it has after any normal use.
    static func fakeBrew(_ home: HomeFixture, formulaList: Bool = true) throws -> String {
        try home.file("/Users/u/x", bytes: 10)
        if formulaList { try home.file("/Users/u/Library/Caches/Homebrew/api/formula.jws.json", bytes: 10) }
        let brew = try home.fx.file("bin/brew", bytes: 10)
        chmod(brew, 0o755)
        return brew
    }

    @Test func parsesDryRunTotal() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        let brew = try Self.fakeBrew(home)
        let tree = try await home.scan()
        let runner = FakeCommandRunner(["\(brew) cleanup --prune=all --dry-run": .success(try Fixtures.data("brew-cleanup-dry-run.txt"))])
        let items = await HomebrewDetector(brewPaths: [brew]).detect(in: .test(tree: tree, kb: try .test([]), runner: runner))
        let item = try #require(items.first)
        #expect(item.title == "Old Homebrew versions and downloads")
        #expect(item.bytes == 1_288_490_188)
        #expect(item.safety == .safe)
        #expect(item.action == .tool(ToolCommand(toolName: "Homebrew", executable: brew, arguments: ["cleanup", "--prune=all"])))
    }

    @Test func passesNoNetworkEnvironment() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        let brew = try Self.fakeBrew(home)
        let tree = try await home.scan()
        let runner = FakeCommandRunner(["\(brew) cleanup --prune=all --dry-run": .success(try Fixtures.data("brew-cleanup-dry-run.txt"))])
        _ = await HomebrewDetector(brewPaths: [brew]).detect(in: .test(tree: tree, kb: try .test([]), runner: runner))
        let environment = try #require(runner.calls.first?.environment)
        #expect(environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(environment["HOMEBREW_NO_ANALYTICS"] == "1")
        #expect(environment["HOMEBREW_NO_ENV_HINTS"] == "1")
    }

    /// Without its cached formula list, any brew command downloads it first.
    @Test func staysOfflineWithoutTheFormulaList() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        let brew = try Self.fakeBrew(home, formulaList: false)
        let tree = try await home.scan()
        let runner = FakeCommandRunner(["\(brew) cleanup --prune=all --dry-run": .success(try Fixtures.data("brew-cleanup-dry-run.txt"))])
        let items = await HomebrewDetector(brewPaths: [brew]).detect(in: .test(tree: tree, kb: try .test([]), runner: runner))
        #expect(items.isEmpty)
        #expect(runner.calls.isEmpty)
    }

    /// With casks installed, cleanup reads the cask list too, and would download it if missing.
    @Test func staysOfflineWithoutTheCaskListWhenCasksAreInstalled() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        let brew = try Self.fakeBrew(home)
        try home.fx.file("Caskroom/firefox/150.0/Firefox.app/x", bytes: 10)
        let tree = try await home.scan()
        let runner = FakeCommandRunner(["\(brew) cleanup --prune=all --dry-run": .success(try Fixtures.data("brew-cleanup-dry-run.txt"))])
        #expect(await HomebrewDetector(brewPaths: [brew]).detect(in: .test(tree: tree, kb: try .test([]), runner: runner)).isEmpty)
        #expect(runner.calls.isEmpty)
        try home.file("/Users/u/Library/Caches/Homebrew/api/cask.jws.json", bytes: 10)
        let rescanned = try await home.scan()
        #expect(await HomebrewDetector(brewPaths: [brew]).detect(in: .test(tree: rescanned, kb: try .test([]), runner: runner)).count == 1)
    }

    @Test func noBrewNoItem() async throws {
        let home = try HomeFixture()
        defer { home.remove() }
        try home.file("/Users/u/x", bytes: 10)
        let tree = try await home.scan()
        let runner = FakeCommandRunner()
        let items = await HomebrewDetector(brewPaths: ["/nonexistent/brew"]).detect(in: .test(tree: tree, kb: try .test([]), runner: runner))
        #expect(items.isEmpty)
        #expect(runner.calls.isEmpty)
    }

    @Test func parsesEveryUnit() {
        #expect(HomebrewDetector.parseFreedBytes("would free approximately 512B of disk space") == 512)
        #expect(HomebrewDetector.parseFreedBytes("would free approximately 2KB of disk space") == 2_048)
        #expect(HomebrewDetector.parseFreedBytes("would free approximately 1.5MB of disk space") == 1_572_864)
        #expect(HomebrewDetector.parseFreedBytes("nothing to clean") == nil)
    }
}
