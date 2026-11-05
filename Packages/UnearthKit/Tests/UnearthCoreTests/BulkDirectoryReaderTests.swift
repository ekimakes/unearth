import Darwin
import Foundation
import Testing
@testable import UnearthCore

struct BulkDirectoryReaderTests {
    let reader = BulkDirectoryReader()

    @Test func matchesFileManagerOracle() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        for d in 0..<3 {
            for i in 0..<100 {
                try fx.file("d\(d)/f\(i)", bytes: Int.random(in: 0...200_000))
            }
        }
        for d in 0..<3 {
            let directory = fx.path("d\(d)")
            let entries = try reader.entries(ofDirectoryAt: directory)
            #expect(entries.count == 100)
            for entry in entries {
                let values = try URL(fileURLWithPath: directory + "/" + entry.name)
                    .resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                #expect(entry.kind == .file)
                #expect(entry.allocatedSize == Int64(values.totalFileAllocatedSize ?? -1))
                #expect(entry.logicalSize == Int64(values.fileSize ?? -1))
            }
        }
        let top = try reader.entries(ofDirectoryAt: fx.root)
        #expect(top.allSatisfy { $0.kind == .directory })
        #expect(Set(top.map(\.name)) == ["d0", "d1", "d2"])
    }

    /// The Library sorts by "date added"; creation dates fill in where a volume has none.
    @Test func reportsCreationAndAddedDates() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        for i in 0..<20 { try fx.file("f\(i)", bytes: 100) }
        try fx.dir("sub")
        let entries = try reader.entries(ofDirectoryAt: fx.root)
        #expect(entries.count == 21)
        for entry in entries {
            let values = try URL(fileURLWithPath: fx.path(entry.name))
                .resourceValues(forKeys: [.creationDateKey, .addedToDirectoryDateKey])
            let created = try #require(entry.creationDate)
            let added = try #require(entry.addedDate)
            #expect(abs(created.timeIntervalSince(try #require(values.creationDate))) < 1)
            #expect(abs(added.timeIntervalSince(try #require(values.addedToDirectoryDate))) < 1)
        }
    }

    @Test func reportsHardLinksAndClones() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let original = try fx.file("a", bytes: 2_000_000)
        try fx.hardLink(original, fx.path("b"))
        let source = try fx.file("c", bytes: 2_000_000)
        try fx.clone(source, fx.path("c-clone"))

        let byName = Dictionary(uniqueKeysWithValues: try reader.entries(ofDirectoryAt: fx.root).map { ($0.name, $0) })
        #expect(byName["a"]?.linkCount == 2)
        #expect(byName["b"]?.linkCount == 2)
        #expect(byName["a"]?.fileID == byName["b"]?.fileID)

        let clonedFrom = try #require(byName["c"])
        let clone = try #require(byName["c-clone"])
        #expect(clonedFrom.mayShareBlocks)
        #expect(clone.mayShareBlocks)
        #expect(clone.cloneID != 0)
        #expect(clone.cloneID == clonedFrom.cloneID)
        let privateBytes = try #require(reader.privateSize(ofFileAt: fx.path("c-clone")))
        #expect(privateBytes < 2_000_000)
    }

    @Test func doesNotFollowSymlinks() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let target = try fx.file("big", bytes: 1_000_000)
        try fx.symlink("link", to: target)
        let link = try #require(try reader.entries(ofDirectoryAt: fx.root).first { $0.name == "link" })
        #expect(link.kind == .symlink)
        #expect(link.allocatedSize < 4096)
    }

    @Test func readsDirectoryLargerThanOneBuffer() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let many = try fx.dir("many")
        for i in 0..<6_000 {
            FileManager.default.createFile(atPath: many + "/file-\(i)", contents: nil)
        }
        let entries = try reader.entries(ofDirectoryAt: many)
        #expect(entries.count == 6_000)
        #expect(Set(entries.map(\.name)).count == 6_000)
    }

    @Test func readsDirectoryBeyondPathMax() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let components = (0..<25).map { "level-\($0)-" + String(repeating: "x", count: 52) }
        let deepest = try fx.deepDirectory(components, fileName: "bottom.txt", bytes: 10_000)
        #expect(deepest.utf8.count > 1_500)
        let entries = try reader.entries(ofDirectoryAt: deepest)
        #expect(entries.map(\.name) == ["bottom.txt"])
        #expect(entries.first?.logicalSize == 10_000)
    }

    @Test func preservesUnusualNames() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let names = ["a b", "emoji 🗂", "e\u{301}"]
        for name in names { try fx.file(name, bytes: 10) }
        let returned = try reader.entries(ofDirectoryAt: fx.root).map { Array($0.name.utf8) }
        for name in names {
            #expect(returned.contains(Array(name.utf8)))
        }
    }

    @Test func throwsPermissionDenied() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let locked = try fx.dir("locked")
        try fx.file("locked/x", bytes: 10)
        chmod(locked, 0o000)
        defer { chmod(locked, 0o755) }
        #expect(throws: DirectoryReadError.permissionDenied) {
            try reader.entries(ofDirectoryAt: locked)
        }
    }

    /// A mount point is listed with its parent's device id, so only the mount status gives it away.
    /// /dev is always its own file system (devfs), mounted inside the root folder.
    @Test func reportsMountPoints() throws {
        let root = try BulkDirectoryReader().entries(ofDirectoryAt: "/")
        #expect(root.first { $0.name == "dev" }?.isMountPoint == true)
        #expect(root.first { $0.name == "usr" }?.isMountPoint == false)
        #expect(root.first { $0.name == "usr" }?.kind == .directory)
    }

    @Test func reportsDeviceOfDirectory() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        var info = stat()
        #expect(lstat(fx.root, &info) == 0)
        #expect(try reader.deviceID(ofDirectoryAt: fx.root) == info.st_dev)
    }
}

struct PathsTests {
    @Test func joinHandlesRoot() {
        #expect(Paths.join("/", "Users") == "/Users")
        #expect(Paths.join("/a", "b") == "/a/b")
    }

    @Test func insideIsComponentWise() {
        #expect(Paths.isSameOrInside("/a/b", "/a/b"))
        #expect(Paths.isSameOrInside("/a/b/c", "/a/b"))
        #expect(!Paths.isSameOrInside("/a/bc", "/a/b"))
        #expect(!Paths.isSameOrInside("/a", "/a/b"))
        #expect(Paths.isSameOrInside("/a", "/"))
    }

    /// APFS volumes are case- and normalization-insensitive by default, so these name the same folder.
    @Test func comparesLikeAPFS() {
        #expect(Paths.isSameOrInside("/x/e\u{301}/y", "/x/\u{e9}"))
        #expect(Paths.isSameOrInside("/Users/A/Projects/x", "/users/a/projects"))
    }
}
