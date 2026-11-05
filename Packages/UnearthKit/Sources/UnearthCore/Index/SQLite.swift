import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

enum SQLValue {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null

    static func optional(_ text: String?) -> SQLValue { text.map(SQLValue.text) ?? .null }
    static func optional(_ date: Date?) -> SQLValue { date.map { .real($0.timeIntervalSince1970) } ?? .null }
}

/// The system SQLite, one connection, used from a single actor.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws(SQLiteError) {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Can't open \(path)."
            sqlite3_close_v2(handle)
            throw SQLiteError(message: message)
        }
    }

    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String) throws(SQLiteError) {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    func prepare(_ sql: String) throws(SQLiteError) -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil) == SQLITE_OK,
              let statement else { throw lastError() }
        return SQLiteStatement(statement, database: self)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Rows changed by the last statement.
    var changes: Int { Int(sqlite3_changes(handle)) }

    func lastError() -> SQLiteError {
        SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
    }
}

final class SQLiteStatement {
    private let handle: OpaquePointer
    private let database: SQLiteDatabase
    /// Tells SQLite to copy bound text, since Swift strings don't outlive the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ handle: OpaquePointer, database: SQLiteDatabase) {
        self.handle = handle
        self.database = database
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ values: [SQLValue]) throws(SQLiteError) {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status = switch value {
            case .integer(let number): sqlite3_bind_int64(handle, index, number)
            case .real(let number): sqlite3_bind_double(handle, index, number)
            case .text(let text): sqlite3_bind_text(handle, index, text, -1, Self.transient)
            case .blob(let data): data.withUnsafeBytes { sqlite3_bind_blob(handle, index, $0.baseAddress, Int32($0.count), Self.transient) }
            case .null: sqlite3_bind_null(handle, index)
            }
            guard status == SQLITE_OK else { throw database.lastError() }
        }
    }

    /// True while there's a row to read.
    func step() throws(SQLiteError) -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw database.lastError()
        }
    }

    func run(_ values: [SQLValue] = []) throws(SQLiteError) {
        try bind(values)
        while try step() {}
    }

    func rows<T>(_ values: [SQLValue] = [], _ read: (SQLiteStatement) -> T) throws(SQLiteError) -> [T] {
        try bind(values)
        var results: [T] = []
        while try step() { results.append(read(self)) }
        return results
    }

    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }

    func text(_ column: Int32) -> String? {
        sqlite3_column_text(handle, column).map { String(cString: $0) }
    }

    func data(_ column: Int32) -> Data? {
        guard !isNull(column) else { return nil }
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0, let bytes = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    func date(_ column: Int32) -> Date? {
        isNull(column) ? nil : Date(timeIntervalSince1970: double(column))
    }
}
