import Foundation
import Testing
@testable import UnearthCore

struct VolumeInventoryTests {
    @Test func parsesBootContainer() throws {
        let containers = try VolumeInventory.parseContainers(Fixtures.data("diskutil-apfs-list.plist"))
        let boot = try #require(containers.first { $0.reference == "disk3" })
        #expect(boot.volumes.count == 6)
        #expect(boot.capacity == 994_662_584_320)
        #expect(boot.free == 54_185_586_688)
        let inventory = VolumeInventory(container: boot, available: 1, availableForImportantUsage: 1)
        #expect(inventory.volume(withRole: "Data")?.capacityInUse == 904_399_007_744)
        #expect(inventory.volume(withRole: "System")?.name == "Macintosh HD")
    }

    @Test func computesUsedAndPurgeable() throws {
        let containers = try VolumeInventory.parseContainers(Fixtures.data("diskutil-apfs-list.plist"))
        let boot = try #require(containers.first { $0.reference == "disk3" })
        let inventory = VolumeInventory(container: boot, available: 54_182_469_632, availableForImportantUsage: 60_977_076_153)
        #expect(inventory.used == 940_476_997_632)
        #expect(inventory.purgeable == 6_794_606_521)
    }

    @Test func purgeableNeverNegative() throws {
        let container = APFSContainer(reference: "disk3", capacity: 100, free: 50, volumes: [])
        #expect(VolumeInventory(container: container, available: 60, availableForImportantUsage: 40).purgeable == 0)
    }

    @Test func loadsUsingFakeRunner() async throws {
        let runner = FakeCommandRunner([
            "/usr/sbin/diskutil info -plist /": .success(try Fixtures.data("diskutil-info-root.plist")),
            "/usr/sbin/diskutil apfs list -plist": .success(try Fixtures.data("diskutil-apfs-list.plist")),
        ])
        let inventory = try await VolumeInventory.load(runner: runner, capacities: { (available: 10, importantUsage: 15) })
        #expect(inventory.container.reference == "disk3")
        #expect(inventory.purgeable == 5)
        #expect(runner.calls.map(\.arguments) == [["info", "-plist", "/"], ["apfs", "list", "-plist"]])
    }
}

struct ProcessCommandRunnerTests {
    @Test func runsProcessAndCapturesOutput() async throws {
        let result = try await ProcessCommandRunner().run("/bin/echo", ["hello"], environment: [:])
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hello\n")
    }

    @Test func addsEnvironmentOnTopOfInherited() async throws {
        let result = try await ProcessCommandRunner().run("/usr/bin/env", [], environment: ["UNEARTH_TEST_FLAG": "1"])
        let output = String(decoding: result.stdout, as: UTF8.self)
        #expect(output.contains("UNEARTH_TEST_FLAG=1"))
        #expect(output.contains("PATH="))
    }

    @Test func capturesLargeOutputWithoutDeadlock() async throws {
        let result = try await ProcessCommandRunner().run("/bin/dd", ["if=/dev/zero", "bs=1024", "count=300"], environment: [:])
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 300 * 1024)
    }
}
