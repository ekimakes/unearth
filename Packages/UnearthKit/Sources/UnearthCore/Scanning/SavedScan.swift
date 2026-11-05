import Foundation

/// The last scan, kept on disk: scanning a full Mac takes about a minute, so the next launch shows this at once and
/// checks the disk behind it.
public struct SavedScan: Sendable {
    /// How long a saved scan stands in for a new one when the app opens.
    public static let freshFor: TimeInterval = 3_600

    public struct Loaded: Sendable {
        public let tree: ScanTree
        public let hadFullDiskAccess: Bool
        public let age: TimeInterval

        public var isFresh: Bool { age < SavedScan.freshFor }
    }

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Nil when there's nothing saved or it can't be read.
    public func load() -> Loaded? {
        guard let bytes = try? Data(contentsOf: fileURL, options: .alwaysMapped), let flag = bytes.first,
              let tree = ScanTree.unarchived(bytes.dropFirst()),
              let saved = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date else {
            return nil
        }
        return Loaded(tree: tree, hadFullDiskAccess: flag == 1, age: Date().timeIntervalSince(saved))
    }

    public func save(_ tree: ScanTree, fullDiskAccess: Bool) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = Data([fullDiskAccess ? 1 : 0])
        bytes.append(tree.archived())
        try bytes.write(to: fileURL, options: .atomic)
    }

    /// The disk changed: the next launch checks it again, whatever this scan's age.
    public func markOutdated() {
        try? FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: fileURL.path)
    }

    public func forget() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

extension ScanTree {
    private static let magic: UInt32 = 0x5453_4E55
    /// Bump when `ScanNode`, `BigFile` or `ScanStats` change: an older file then reads as nothing.
    private static let version: UInt32 = 1

    /// The tree as bytes. Paths and sizes stay on this Mac, like the index.
    func archived() -> Data {
        var writer = ArchiveWriter(capacity: nodeCount * 96)
        writer.put(Self.magic)
        writer.put(Self.version)
        writer.put(rootPath)
        writer.put(displayRoot)
        writer.put(Int64(stats.files))
        writer.put(Int64(stats.directories))
        writer.put(Int64(stats.inaccessibleDirectories))
        writer.put(Int64(stats.mountPointsSkipped))
        writer.put(Int64(stats.cloudOnlyFiles))
        writer.put(stats.elapsed.components.seconds)
        writer.put(stats.elapsed.components.attoseconds)
        writer.put(UInt32(nodeCount))
        for raw in 0..<Int32(nodeCount) {
            let node = node(NodeID(raw: raw))
            writer.put(node.name)
            writer.put(node.parent?.raw ?? -1)
            writer.put(UInt32(node.children.count))
            for child in node.children { writer.put(child.raw) }
            writer.put(node.ownBytes)
            writer.put(node.ownMediaBytes)
            writer.put(node.ownFileCount)
            writer.put(node.markers.rawValue)
            writer.put(UInt8(node.isInaccessible ? 1 : 0))
            writer.put(node.totalBytes)
            writer.put(node.totalMediaBytes)
            writer.put(node.totalFileCount)
            writer.put(node.newestOwnModification)
            writer.put(node.newestModification)
        }
        writer.put(UInt32(bigFiles.count))
        for file in bigFiles {
            writer.put(file.path)
            writer.put(file.bytes)
            writer.put(file.modificationDate as Date?)
            writer.put(UInt8(file.isMedia ? 1 : 0))
        }
        return Data(writer.bytes)
    }

    /// Nil for anything but an intact archive of this version.
    static func unarchived(_ data: Data) -> ScanTree? {
        data.withUnsafeBytes { bytes -> ScanTree? in
            var reader = ArchiveReader(bytes: bytes)
            return try? read(from: &reader)
        }
    }

    private static func read(from reader: inout ArchiveReader) throws -> ScanTree {
        guard try reader.next(UInt32.self) == magic, try reader.next(UInt32.self) == version else { throw ArchiveReader.Damaged() }
        let rootPath = try reader.string()
        let displayRoot = try reader.string()
        let files = try reader.next(Int64.self), directories = try reader.next(Int64.self)
        let inaccessible = try reader.next(Int64.self), mountPoints = try reader.next(Int64.self), cloudOnly = try reader.next(Int64.self)
        let elapsed = Duration(secondsComponent: try reader.next(Int64.self), attosecondsComponent: try reader.next(Int64.self))
        let count = Int(try reader.next(UInt32.self))
        // Every node takes dozens of bytes, so a damaged count can't ask for more than the file could hold.
        guard count > 0, count <= reader.remaining / 16 else { throw ArchiveReader.Damaged() }
        func id(_ raw: Int32) throws -> NodeID {
            guard raw >= 0, raw < count else { throw ArchiveReader.Damaged() }
            return NodeID(raw: raw)
        }
        var nodes: [ScanNode] = []
        nodes.reserveCapacity(count)
        for _ in 0..<count {
            let name = try reader.string()
            let parent = try reader.next(Int32.self)
            var children: [NodeID] = []
            let childCount = Int(try reader.next(UInt32.self))
            guard childCount <= reader.remaining / 4 else { throw ArchiveReader.Damaged() }
            children.reserveCapacity(childCount)
            for _ in 0..<childCount { children.append(try id(try reader.next(Int32.self))) }
            nodes.append(ScanNode(
                name: name, parent: parent < 0 ? nil : try id(parent), children: children,
                ownBytes: try reader.next(Int64.self), ownMediaBytes: try reader.next(Int64.self), ownFileCount: try reader.next(Int32.self),
                markers: ProjectMarkers(rawValue: try reader.next(UInt16.self)), isInaccessible: try reader.next(UInt8.self) == 1,
                totalBytes: try reader.next(Int64.self), totalMediaBytes: try reader.next(Int64.self), totalFileCount: try reader.next(Int64.self),
                newestOwnModification: try reader.date(), newestModification: try reader.date()))
        }
        let bigFileCount = Int(try reader.next(UInt32.self))
        guard bigFileCount <= reader.remaining / 16 else { throw ArchiveReader.Damaged() }
        var bigFiles: [BigFile] = []
        bigFiles.reserveCapacity(bigFileCount)
        for _ in 0..<bigFileCount {
            let path = try reader.string()
            let bytes = try reader.next(Int64.self)
            guard let modified = try reader.date() else { throw ArchiveReader.Damaged() }
            bigFiles.append(BigFile(path: path, bytes: bytes, modificationDate: modified, isMedia: try reader.next(UInt8.self) == 1))
        }
        let stats = ScanStats(files: Int(files), directories: Int(directories), inaccessibleDirectories: Int(inaccessible),
                              mountPointsSkipped: Int(mountPoints), cloudOnlyFiles: Int(cloudOnly), elapsed: elapsed)
        return ScanTree(nodes: nodes, rootPath: rootPath, displayRoot: displayRoot, bigFiles: bigFiles, stats: stats)
    }
}

private struct ArchiveWriter {
    var bytes: [UInt8] = []

    init(capacity: Int) {
        bytes.reserveCapacity(capacity)
    }

    mutating func put<Value: FixedWidthInteger>(_ value: Value) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func put(_ string: String) {
        var string = string
        string.withUTF8 { utf8 in
            put(UInt32(utf8.count))
            bytes.append(contentsOf: utf8)
        }
    }

    /// NaN stands for no date.
    mutating func put(_ date: Date?) {
        put((date?.timeIntervalSinceReferenceDate ?? .nan).bitPattern)
    }
}

private struct ArchiveReader {
    struct Damaged: Error {}

    let bytes: UnsafeRawBufferPointer
    var offset = 0

    var remaining: Int { bytes.count - offset }

    mutating func next<Value: FixedWidthInteger>(_ type: Value.Type) throws -> Value {
        guard remaining >= MemoryLayout<Value>.size else { throw Damaged() }
        defer { offset += MemoryLayout<Value>.size }
        return Value(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Value.self))
    }

    mutating func string() throws -> String {
        let length = Int(try next(UInt32.self))
        guard remaining >= length else { throw Damaged() }
        defer { offset += length }
        return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + length)]), as: UTF8.self)
    }

    mutating func date() throws -> Date? {
        let seconds = Double(bitPattern: try next(UInt64.self))
        return seconds.isNaN ? nil : Date(timeIntervalSinceReferenceDate: seconds)
    }
}
