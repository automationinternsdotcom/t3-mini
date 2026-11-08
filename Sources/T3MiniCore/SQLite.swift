import Foundation
import SQLite3

/// Minimal read-only SQLite wrapper. T3 Code owns the database; we never write.
public final class SQLiteReader {
    public enum Failure: Error, CustomStringConvertible {
        case open(String)
        case prepare(String, String)
        public var description: String {
            switch self {
            case .open(let m): return "open failed: \(m)"
            case .prepare(let sql, let m): return "prepare failed (\(m)): \(sql.prefix(80))"
            }
        }
    }

    private var db: OpaquePointer?
    public let path: String

    public init(path: String) throws {
        self.path = path
        // mode=ro: never take a write lock. Not immutable: T3 keeps writing via WAL.
        let uri = "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(uri, &db, flags, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            db = nil
            throw Failure.open(msg)
        }
        sqlite3_busy_timeout(db, 250)
        _ = try? rows("PRAGMA query_only = ON")
    }

    deinit { sqlite3_close(db) }

    /// Changes whenever another connection (T3) commits. Cheap change detection.
    public func dataVersion() -> Int64 {
        (try? rows("PRAGMA data_version").first?.int(0)) ?? -1
    }

    public func rows(_ sql: String, _ args: [Any?] = []) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Failure.prepare(sql, String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, idx)
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, transient)
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int64: sqlite3_bind_int64(stmt, idx, n)
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            default: sqlite3_bind_text(stmt, idx, "\(arg!)", -1, transient)
            }
        }
        var out: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                var values: [Any?] = []
                for c in 0..<sqlite3_column_count(stmt) {
                    switch sqlite3_column_type(stmt, c) {
                    case SQLITE_INTEGER: values.append(sqlite3_column_int64(stmt, c))
                    case SQLITE_FLOAT: values.append(sqlite3_column_double(stmt, c))
                    case SQLITE_NULL: values.append(nil)
                    default:
                        if let t = sqlite3_column_text(stmt, c) {
                            values.append(String(cString: t))
                        } else {
                            values.append(nil)
                        }
                    }
                }
                out.append(Row(values: values))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw Failure.prepare(sql, String(cString: sqlite3_errmsg(db)))
            }
        }
        return out
    }

    public struct Row {
        public let values: [Any?]
        public func string(_ i: Int) -> String? { values[i] as? String }
        public func int(_ i: Int) -> Int64? {
            if let n = values[i] as? Int64 { return n }
            if let s = values[i] as? String { return Int64(s) }
            return nil
        }
    }
}

/// T3 stores ISO-8601 timestamps with fractional seconds ("2026-11-08T00:10:17.913Z").
public enum ISODate {
    private static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    public static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return frac.date(from: s) ?? plain.date(from: s)
    }

    public static func string(_ d: Date) -> String { frac.string(from: d) }
}
