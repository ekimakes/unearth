@testable import UnearthCore

/// An in-memory directory tree: listings by absolute path, plus forced failures.
struct FakeDirectoryReader: DirectoryReading {
    var listings: [String: [DirectoryEntry]]
    var failures: [String: DirectoryReadError] = [:]
    var rootDevice: Int32 = 1

    func entries(ofDirectoryAt path: String) throws(DirectoryReadError) -> [DirectoryEntry] {
        if let failure = failures[path] { throw failure }
        guard let listing = listings[path] else { throw .notFound }
        return listing
    }

    func privateSize(ofFileAt path: String) -> Int64? { nil }

    func deviceID(ofDirectoryAt path: String) throws(DirectoryReadError) -> Int32 { rootDevice }
}

extension DirectoryEntry {
    static func fakeFile(_ name: String, bytes: Int64, dataless: Bool = false) -> DirectoryEntry {
        DirectoryEntry(name: name, kind: .file, deviceID: 1, fileID: UInt64(name.hashValue.magnitude),
                       allocatedSize: bytes, logicalSize: bytes, isDataless: dataless)
    }

    /// Like the kernel, a mount point carries its parent's device id; only `mountPoint` marks it.
    static func fakeDirectory(_ name: String, mountPoint: Bool = false) -> DirectoryEntry {
        DirectoryEntry(name: name, kind: .directory, deviceID: 1, isMountPoint: mountPoint)
    }
}
