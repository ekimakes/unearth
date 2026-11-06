import Foundation

public struct APFSVolume: Sendable, Equatable {
    public let deviceIdentifier: String
    public let name: String
    /// "System", "Data", "VM", "Preboot", "Recovery", "Update", …
    public let roles: [String]
    public let capacityInUse: Int64

    public init(deviceIdentifier: String, name: String, roles: [String], capacityInUse: Int64) {
        self.deviceIdentifier = deviceIdentifier
        self.name = name
        self.roles = roles
        self.capacityInUse = capacityInUse
    }
}

public struct APFSContainer: Sendable, Equatable {
    public let reference: String
    public let capacity: Int64
    public let free: Int64
    public let volumes: [APFSVolume]

    public init(reference: String, capacity: Int64, free: Int64, volumes: [APFSVolume]) {
        self.reference = reference
        self.capacity = capacity
        self.free = free
        self.volumes = volumes
    }
}

public enum VolumeInventoryError: Error, Equatable {
    case diskutilFailed(String)
    case bootContainerNotFound
}

/// The startup disk's APFS container: how much each volume uses, and what's free.
public struct VolumeInventory: Sendable, Equatable {
    public let container: APFSContainer
    public let available: Int64
    /// Free space including what macOS can purge on demand.
    public let availableForImportantUsage: Int64

    public init(container: APFSContainer, available: Int64, availableForImportantUsage: Int64) {
        self.container = container
        self.available = available
        self.availableForImportantUsage = availableForImportantUsage
    }

    public var used: Int64 { container.capacity - container.free }
    public var purgeable: Int64 { max(0, availableForImportantUsage - available) }

    public func volume(withRole role: String) -> APFSVolume? {
        container.volumes.first { $0.roles.contains(role) }
    }

    /// The smallest change the free-space meter can show: it counts hundredths of a gigabyte.
    static let smallestVisibleChange: Int64 = 10_000_000

    /// This disk with `now` bytes available, or nil if that's too small a change to show. Only what's free moves:
    /// what each volume uses stays as it was loaded, until the next `load`.
    public func refreshed(available now: Int64) -> VolumeInventory? {
        let change = now - available
        guard abs(change) >= Self.smallestVisibleChange else { return nil }
        let free = min(container.capacity, max(0, container.free + change))
        return VolumeInventory(
            container: APFSContainer(reference: container.reference, capacity: container.capacity, free: free, volumes: container.volumes),
            available: now, availableForImportantUsage: availableForImportantUsage + change)
    }

    /// What's available on the volume holding `path`. Unlike `load`, this costs next to nothing.
    public static func availableCapacity(at path: String = "/") -> Int64? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    public static func parseContainers(_ plist: Data) throws -> [APFSContainer] {
        let root = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        guard let containers = root?["Containers"] as? [[String: Any]] else {
            throw VolumeInventoryError.diskutilFailed("no Containers in diskutil output")
        }
        return containers.map { container in
            let volumes = (container["Volumes"] as? [[String: Any]] ?? []).map { volume in
                APFSVolume(
                    deviceIdentifier: volume["DeviceIdentifier"] as? String ?? "",
                    name: volume["Name"] as? String ?? "",
                    roles: volume["Roles"] as? [String] ?? [],
                    capacityInUse: int64(volume["CapacityInUse"]))
            }
            return APFSContainer(
                reference: container["ContainerReference"] as? String ?? "",
                capacity: int64(container["CapacityCeiling"]),
                free: int64(container["CapacityFree"]),
                volumes: volumes)
        }
    }

    public static func load(
        runner: any CommandRunning,
        capacities: @Sendable () throws -> (available: Int64, importantUsage: Int64) = Self.startupDiskCapacities
    ) async throws -> VolumeInventory {
        let info = try await runner.run("/usr/sbin/diskutil", ["info", "-plist", "/"], environment: [:])
        guard info.exitCode == 0,
              let infoPlist = try? PropertyListSerialization.propertyList(from: info.stdout, format: nil) as? [String: Any],
              let reference = infoPlist["APFSContainerReference"] as? String else {
            throw VolumeInventoryError.diskutilFailed(String(decoding: info.stderr, as: UTF8.self))
        }
        let list = try await runner.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], environment: [:])
        guard list.exitCode == 0 else {
            throw VolumeInventoryError.diskutilFailed(String(decoding: list.stderr, as: UTF8.self))
        }
        guard let container = try parseContainers(list.stdout).first(where: { $0.reference == reference }) else {
            throw VolumeInventoryError.bootContainerNotFound
        }
        let (available, importantUsage) = try capacities()
        return VolumeInventory(container: container, available: available, availableForImportantUsage: importantUsage)
    }

    @Sendable public static func startupDiskCapacities() throws -> (available: Int64, importantUsage: Int64) {
        let values = try URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (Int64(values.volumeAvailableCapacity ?? 0), values.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    private static func int64(_ value: Any?) -> Int64 {
        (value as? NSNumber)?.int64Value ?? 0
    }
}
