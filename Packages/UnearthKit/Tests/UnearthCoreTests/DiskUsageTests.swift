import Foundation
import Testing
@testable import UnearthCore

struct DiskUsageTests {
    /// What moving something to the Trash would free once it's emptied: blocks on this Mac, not the
    /// file's length (an iCloud-only file takes none).
    @Test func onDiskSizesMatchFinder() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let small = try fx.file("folder/small.txt", bytes: 100)
        try fx.file("folder/sub/big.bin", bytes: 300_000)
        let allocated = { (path: String) in
            Int64(try URL(fileURLWithPath: path).resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? -1)
        }
        #expect(DiskUsage.onDisk(small) == (try allocated(small)))
        #expect(DiskUsage.onDisk(fx.path("folder")) == (try allocated(small)) + (try allocated(fx.path("folder/sub/big.bin"))))
        #expect(DiskUsage.onDisk(fx.path("missing")) == 0)
    }

    /// A file on a drive that isn't plugged in is offline, not deleted.
    @Test func knowsWhenAFilesDriveIsMissing() {
        #expect(DiskUsage.isOnDisconnectedVolume("/Volumes/No Such Drive \(UUID().uuidString)/Photos/a.jpg"))
        #expect(!DiskUsage.isOnDisconnectedVolume("/Users/nobody-\(UUID().uuidString)/a.jpg"))
        #expect(!DiskUsage.isOnDisconnectedVolume("/Volumes"))
    }
}
