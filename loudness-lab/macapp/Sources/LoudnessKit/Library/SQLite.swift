import Foundation
import SQLite3

/// A thin wrapper over the system SQLite, so the library needs no packages.
///
/// Deliberately small: open, exec, prepare, bind, step. Anything more would
/// be a database layer, and what this project needs is the same handful of
/// statements the Python already writes, run against the same file.
public final class SQLite {

    /// SQLite's own "copy this string, I will not keep your pointer". Swift
    /// does not import the macro, and binding without it hands the database a
    /// pointer to memory that is about to go away.
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public struct Failure: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private var handle: OpaquePointer?

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw Failure("could not open \(path): \(message)")
        }
    }

    deinit { sqlite3_close(handle) }

    var message: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "?" }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let text = error.map { String(cString: $0) } ?? message
            sqlite3_free(error)
            throw Failure(text)
        }
    }

    public enum Value {
        case null, int(Int64), double(Double), text(String)

        public init(_ value: Int?) { self = value.map { .int(Int64($0)) } ?? .null }
        public init(_ value: Double?) {
            // A non-finite value has no SQLite representation; -inf loudness
            // for a silent track is genuinely "unknown", so it is stored that
            // way instead of as a number that would be averaged into reports.
            guard let value, value.isFinite else { self = .null; return }
            self = .double(value)
        }
        public init(_ value: String?) { self = value.map { .text($0) } ?? .null }
        public init(_ value: Bool?) { self = value.map { .int($0 ? 1 : 0) } ?? .null }
    }

    public struct Row {
        let columns: [String: Int32]
        let statement: OpaquePointer

        public func int(_ name: String) -> Int? {
            guard let index = columns[name],
                  sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int64(statement, index))
        }
        public func double(_ name: String) -> Double? {
            guard let index = columns[name],
                  sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            return sqlite3_column_double(statement, index)
        }
        public func text(_ name: String) -> String? {
            guard let index = columns[name],
                  let pointer = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: pointer)
        }
    }

    @discardableResult
    public func run(_ sql: String, _ values: [Value] = []) throws -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure("\(message) in: \(sql)")
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .int(let number): sqlite3_bind_int64(statement, index, number)
            case .double(let number): sqlite3_bind_double(statement, index, number)
            case .text(let string):
                sqlite3_bind_text(statement, index, string, -1, SQLite.transient)
            }
        }

        var names: [String: Int32] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            names[String(cString: sqlite3_column_name(statement, index))] = index
        }

        var rows: [[String: Any]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw Failure(message) }
            guard let statement else { break }
            var row: [String: Any] = [:]
            for (name, index) in names {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, index)
                case SQLITE_TEXT:
                    row[name] = String(cString: sqlite3_column_text(statement, index))
                default: break     // NULL stays absent, so `row["x"] as? T` is nil
                }
            }
            rows.append(row)
        }
        return rows
    }
}
