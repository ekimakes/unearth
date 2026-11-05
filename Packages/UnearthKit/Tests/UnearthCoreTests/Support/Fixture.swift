import Darwin
import Foundation

/// A throwaway folder tree under the temporary directory. Tests only ever touch paths inside `root`.
struct Fixture {
    /// realpath'd, so it starts with /private/var/folders/...
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnearthTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let resolved = realpath(base.path, nil) else { throw Fixture.posixError() }
        root = String(cString: resolved)
        free(resolved)
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    @discardableResult
    func dir(_ relative: String) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    /// Creates the file with exactly these name bytes (no Foundation normalization).
    @discardableResult
    func file(_ relative: String, bytes: Int, modified: Date? = nil) throws -> String {
        let full = path(relative)
        let parent = (full as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let fd = open(full, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard fd >= 0 else { throw Fixture.posixError() }
        defer { close(fd) }
        try Fixture.writeFiller(fd: fd, bytes: bytes)
        if let modified { try setModified(full, modified) }
        return full
    }

    func setModified(_ fullPath: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fullPath)
    }

    func hardLink(_ source: String, _ destination: String) throws {
        guard link(source, destination) == 0 else { throw Fixture.posixError() }
    }

    func clone(_ source: String, _ destination: String) throws {
        guard clonefile(source, destination, 0) == 0 else { throw Fixture.posixError() }
    }

    func symlink(_ relative: String, to destination: String) throws {
        guard Darwin.symlink(destination, path(relative)) == 0 else { throw Fixture.posixError() }
    }

    /// Builds nested folders with `mkdirat`, so the result can be longer than PATH_MAX, and puts one file at the bottom.
    func deepDirectory(_ components: [String], fileName: String, bytes: Int) throws -> String {
        var fd = open(root, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw Fixture.posixError() }
        var full = root
        for component in components {
            guard mkdirat(fd, component, 0o755) == 0 else { close(fd); throw Fixture.posixError() }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY)
            close(fd)
            guard next >= 0 else { throw Fixture.posixError() }
            fd = next
            full += "/" + component
        }
        defer { close(fd) }
        let file = openat(fd, fileName, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard file >= 0 else { throw Fixture.posixError() }
        defer { close(file) }
        try Fixture.writeFiller(fd: file, bytes: bytes)
        return full
    }

    /// Removes the whole tree with fd-relative calls, so trees deeper than PATH_MAX go too.
    func remove() {
        let parent = (root as NSString).deletingLastPathComponent
        let name = (root as NSString).lastPathComponent
        let fd = open(parent, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return }
        Fixture.removeTree(parentFD: fd, name: name)
        close(fd)
    }

    private static func removeTree(parentFD: Int32, name: String) {
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { unlinkat(parentFD, name, 0); return }
        fchmod(fd, 0o755)
        if let dir = fdopendir(dup(fd)) {
            var children: [(String, Bool)] = []
            while let entry = readdir(dir) {
                let childName = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                if childName == "." || childName == ".." { continue }
                children.append((childName, entry.pointee.d_type == DT_DIR))
            }
            closedir(dir)
            for (childName, isDirectory) in children {
                if isDirectory { removeTree(parentFD: fd, name: childName) } else { unlinkat(fd, childName, 0) }
            }
        }
        close(fd)
        unlinkat(parentFD, name, AT_REMOVEDIR)
    }

    private static func writeFiller(fd: Int32, bytes: Int) throws {
        guard bytes > 0 else { return }
        let chunk = [UInt8](repeating: 0xAB, count: min(bytes, 1 << 20))
        var remaining = bytes
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            let written = chunk.withUnsafeBytes { write(fd, $0.baseAddress, count) }
            guard written == count else { throw posixError() }
            remaining -= count
        }
    }

    static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
