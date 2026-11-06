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

    private func disk(free: Int64, available: Int64) -> VolumeInventory {
        let system = APFSVolume(deviceIdentifier: "disk3s1", name: "Macintosh HD", roles: ["System"], capacityInUse: 12_000_000_000)
        let container = APFSContainer(reference: "disk3", capacity: 1_000_000_000_000, free: free, volumes: [system])
        return VolumeInventory(container: container, available: available, availableForImportantUsage: available + 7_000_000_000)
    }

    @Test func freeSpaceFollowsTheDisk() throws {
        let before = disk(free: 118_000_000_000, available: 117_900_000_000)
        let after = try #require(before.refreshed(available: 375_900_000_000))
        #expect(after.container.free == 376_000_000_000)
        #expect(after.used == 624_000_000_000)
        #expect(after.available == 375_900_000_000)
        #expect(after.purgeable == before.purgeable)
        #expect(after.container.capacity == before.container.capacity)
        #expect(after.container.volumes == before.container.volumes)
    }

    @Test func freeSpaceFallsToo() throws {
        let before = disk(free: 118_000_000_000, available: 118_000_000_000)
        let after = try #require(before.refreshed(available: 100_000_000_000))
        #expect(after.container.free == 100_000_000_000)
    }

    @Test func changesTooSmallToShowAreLeftOut() {
        let before = disk(free: 118_000_000_000, available: 118_000_000_000)
        #expect(before.refreshed(available: before.available + 9_999_999) == nil)
        #expect(before.refreshed(available: before.available - 9_999_999) == nil)
        #expect(before.refreshed(available: before.available + 10_000_000) != nil)
    }

    @Test func freeSpaceStaysWithinTheDisk() throws {
        let nearlyEmpty = disk(free: 990_000_000_000, available: 990_000_000_000)
        #expect(try #require(nearlyEmpty.refreshed(available: 1_090_000_000_000)).container.free == 1_000_000_000_000)
        let nearlyFull = disk(free: 1_000_000_000, available: 5_000_000_000)
        #expect(try #require(nearlyFull.refreshed(available: 1_000_000_000)).container.free == 0)
    }

    @Test func readsWhatsAvailableOnAVolume() throws {
        #expect(try #require(VolumeInventory.availableCapacity(at: NSTemporaryDirectory())) > 0)
        #expect(VolumeInventory.availableCapacity(at: "/no/such/folder/anywhere") == nil)
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
