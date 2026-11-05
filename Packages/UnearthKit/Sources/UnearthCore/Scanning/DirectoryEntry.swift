import Foundation

public enum EntryKind: Sendable {
    case file, directory, symlink, other
}

/// One item inside a directory, as the file system reports it.
public struct DirectoryEntry: Sendable, Equatable {
    public var name: String
    public var kind: EntryKind
    public var deviceID: Int32
    public var fileID: UInt64
    public var linkCount: UInt32
    /// Bytes the file actually occupies on disk (all forks).
    public var allocatedSize: Int64
    public var logicalSize: Int64
    public var modificationDate: Date
    /// An iCloud placeholder whose contents aren't on this Mac.
    public var isDataless: Bool
    /// The file may share blocks with an APFS clone.
    public var mayShareBlocks: Bool
    /// Pure clones of each other share this id; 0 when unknown.
    public var cloneID: UInt64
    /// Another volume is mounted here, or would be on first access (an automount trigger).
    /// The entry itself still carries the parent's device id.
    public var isMountPoint: Bool
    public var creationDate: Date?
    /// When the item arrived in this folder: downloaded, copied or moved in.
    public var addedDate: Date?

    public init(
        name: String, kind: EntryKind, deviceID: Int32 = 0, fileID: UInt64 = 0, linkCount: UInt32 = 1,
        allocatedSize: Int64 = 0, logicalSize: Int64 = 0, modificationDate: Date = .distantPast,
        isDataless: Bool = false, mayShareBlocks: Bool = false, cloneID: UInt64 = 0, isMountPoint: Bool = false,
        creationDate: Date? = nil, addedDate: Date? = nil
    ) {
        self.name = name
        self.kind = kind
        self.deviceID = deviceID
        self.fileID = fileID
        self.linkCount = linkCount
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.modificationDate = modificationDate
        self.isDataless = isDataless
        self.mayShareBlocks = mayShareBlocks
        self.cloneID = cloneID
        self.isMountPoint = isMountPoint
        self.creationDate = creationDate
        self.addedDate = addedDate
    }
}

public enum DirectoryReadError: Error, Equatable {
    case permissionDenied
    case notFound
    case other(Int32)

    init(errno code: Int32) {
        switch code {
        case EACCES, EPERM: self = .permissionDenied
        case ENOENT, ENOTDIR: self = .notFound
        default: self = .other(code)
        }
    }
}

public protocol DirectoryReading: Sendable {
    func entries(ofDirectoryAt path: String) throws(DirectoryReadError) -> [DirectoryEntry]
    /// Bytes that deleting this file would free right away (clone- and snapshot-aware), if the volume knows.
    func privateSize(ofFileAt path: String) -> Int64?
    func deviceID(ofDirectoryAt path: String) throws(DirectoryReadError) -> Int32
}
