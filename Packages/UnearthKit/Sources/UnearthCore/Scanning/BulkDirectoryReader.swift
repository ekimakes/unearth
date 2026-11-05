import Darwin
import Foundation

/// Reads a whole directory's metadata in a few system calls with `getattrlistbulk`.
public struct BulkDirectoryReader: DirectoryReading {
    private static let bufferSize = 256 * 1024

    public init() {}

    public func entries(ofDirectoryAt path: String) throws(DirectoryReadError) -> [DirectoryEntry] {
        let fd = try Self.openDirectory(path)
        defer { close(fd) }

        var request = Self.bulkRequest()
        let options = UInt64(FSOPT_PACK_INVAL_ATTRS | FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var results: [DirectoryEntry] = []
        while true {
            let count = getattrlistbulk(fd, &request, buffer, Self.bufferSize, options)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw DirectoryReadError(errno: errno)
            }
            var entryStart = buffer
            for _ in 0..<count {
                let length = Int(entryStart.loadUnaligned(as: UInt32.self))
                if let entry = Self.parseEntry(at: entryStart) { results.append(entry) }
                entryStart += length
            }
        }
        return results
    }

    public func privateSize(ofFileAt path: String) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        let options = UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)
        var buffer = (UInt32(0), UInt32(0), UInt32(0), UInt32(0))   // length + off_t, room to spare
        let status = withUnsafeMutableBytes(of: &buffer) { raw in
            Self.withParent(of: path) { parentFD, name in
                getattrlistat(parentFD, name, &request, raw.baseAddress, raw.count, UInt(options))
            }
        }
        guard status == 0 else { return nil }
        return withUnsafeBytes(of: &buffer) { raw in (raw.baseAddress! + 4).loadUnaligned(as: Int64.self) }
    }

    public func deviceID(ofDirectoryAt path: String) throws(DirectoryReadError) -> Int32 {
        let fd = try Self.openDirectory(path)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw DirectoryReadError(errno: errno) }
        return info.st_dev
    }

    // MARK: - Request and parsing

    private static func bulkRequest() -> attrlist {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_CRTIME)
            | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
            | attrgroup_t(ATTR_CMN_ADDEDTIME) | attrgroup_t(ATTR_CMN_ERROR)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
            | attrgroup_t(ATTR_FILE_DATALENGTH)
        // Reinterpreted as extended common attributes because of FSOPT_ATTR_CMN_EXTENDED.
        request.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
        return request
    }

    /// Layout (FSOPT_PACK_INVAL_ATTRS keeps it fixed per object type): length, returned set, error, then
    /// common attributes in bit order, then directory attributes (directories only) or file attributes
    /// (everything else), then extended common attributes.
    private static func parseEntry(at start: UnsafeMutableRawPointer) -> DirectoryEntry? {
        var cursor = UnsafeRawPointer(start) + MemoryLayout<UInt32>.size
        // Which attributes hold real values; the others are packed as zeros.
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size

        let entryError = cursor.loadUnaligned(as: UInt32.self)
        cursor += 4

        let nameReference = cursor.loadUnaligned(as: attrreference_t.self)
        let name = String(cString: (cursor + Int(nameReference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
        cursor += MemoryLayout<attrreference_t>.size

        let deviceID = cursor.loadUnaligned(as: Int32.self)
        cursor += 4
        let objectType = cursor.loadUnaligned(as: UInt32.self)
        cursor += 4
        let created = cursor.loadUnaligned(as: timespec.self)
        cursor += MemoryLayout<timespec>.size
        let modified = cursor.loadUnaligned(as: timespec.self)
        cursor += MemoryLayout<timespec>.size
        let flags = cursor.loadUnaligned(as: UInt32.self)
        cursor += 4
        let fileID = cursor.loadUnaligned(as: UInt64.self)
        cursor += 8
        let added = cursor.loadUnaligned(as: timespec.self)
        cursor += MemoryLayout<timespec>.size

        guard entryError == 0 else { return nil }

        let kind: EntryKind
        switch objectType {
        case UInt32(VREG.rawValue): kind = .file
        case UInt32(VDIR.rawValue): kind = .directory
        case UInt32(VLNK.rawValue): kind = .symlink
        default: kind = .other
        }

        let valid = { (attribute: Int32) in returned.commonattr & attrgroup_t(attribute) != 0 }
        var entry = DirectoryEntry(
            name: name, kind: kind, deviceID: deviceID, fileID: fileID, modificationDate: Self.date(modified),
            isDataless: flags & UInt32(SF_DATALESS) != 0,
            creationDate: valid(ATTR_CMN_CRTIME) ? Self.date(created) : nil,
            addedDate: valid(ATTR_CMN_ADDEDTIME) ? Self.date(added) : nil
        )
        if kind == .directory {
            let mountStatus = cursor.loadUnaligned(as: UInt32.self)
            entry.isMountPoint = mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0
            return entry
        }

        entry.linkCount = cursor.loadUnaligned(as: UInt32.self)
        cursor += 4
        entry.allocatedSize = cursor.loadUnaligned(as: Int64.self)
        cursor += 8
        entry.logicalSize = cursor.loadUnaligned(as: Int64.self)
        cursor += 8
        entry.cloneID = cursor.loadUnaligned(as: UInt64.self)
        cursor += 8
        let extendedFlags = cursor.loadUnaligned(as: UInt64.self)
        entry.mayShareBlocks = extendedFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0
        return entry
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
    }

    // MARK: - Opening paths of any length

    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC

    /// Opens a directory, walking with `openat` when the path is longer than PATH_MAX.
    static func openDirectory(_ path: String) throws(DirectoryReadError) -> Int32 {
        if path.utf8.count < Int(PATH_MAX) {
            let fd = open(path, directoryFlags | O_NOFOLLOW)
            guard fd >= 0 else { throw DirectoryReadError(errno: errno) }
            return fd
        }
        let (prefix, rest) = splitAtPathMax(path)
        var fd = open(prefix, directoryFlags)
        guard fd >= 0 else { throw DirectoryReadError(errno: errno) }
        for component in rest {
            let next = openat(fd, component, directoryFlags | O_NOFOLLOW)
            let code = errno
            close(fd)
            guard next >= 0 else { throw DirectoryReadError(errno: code) }
            fd = next
        }
        return fd
    }

    /// Calls `body` with an fd for the parent directory and the last component's name.
    private static func withParent(of path: String, _ body: (Int32, String) -> Int32) -> Int32 {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let fd = try? openDirectory(parent.isEmpty ? "/" : parent) else { return -1 }
        defer { close(fd) }
        return body(fd, name)
    }

    /// The longest leading part of `path` that fits in PATH_MAX, plus the remaining components.
    private static func splitAtPathMax(_ path: String) -> (String, [String]) {
        let components = path.split(separator: "/").map(String.init)
        var prefix = ""
        var index = 0
        while index < components.count {
            let candidate = prefix + "/" + components[index]
            if candidate.utf8.count >= Int(PATH_MAX) { break }
            prefix = candidate
            index += 1
        }
        return (prefix.isEmpty ? "/" : prefix, Array(components[index...]))
    }
}
