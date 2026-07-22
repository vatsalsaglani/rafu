// Adapted from CodexBar (https://github.com/steipete/CodexBar), MIT
// License — the read-only, bound-parameter SQLite query shape this type
// wraps mirrors CodexBar's local-database readers (its Cursor/OpenCode
// providers). No CodexBar source was copied verbatim; this is a from-
// scratch, minimal reimplementation of the same shape against the system
// `SQLite3` module.

import Foundation
import SQLite3

/// A read-only, bound-parameter SQLite query helper for the local-database
/// usage providers (Cursor's `state.vscdb`, OpenCode's `opencode.db` — see
/// agent-usage-providers.md's provider table). Opens `SQLITE_OPEN_READONLY`
/// only — never creates, writes, or migrates a database — and every
/// parameter is bound (`sqlite3_bind_text` with `SQLITE_TRANSIENT`), never
/// interpolated into the SQL string, matching AGENTS' "never interpolate
/// ... input into a ... command string" discipline extended to SQL. Uses
/// the system `SQLite3` Clang module already available on macOS — no
/// `Package.swift` dependency needed.
nonisolated enum UsageSQLite {
    enum SQLiteError: Error, Sendable {
        case open, prepare, step, bind
    }

    /// Runs `sql` against the read-only database at `databasePath`,
    /// binding each of `parameters` (in order, as `?` placeholders) and
    /// projecting each result row into a `[String: String]` keyed by
    /// `columns` (in the SAME order as the query's `SELECT` list — this
    /// helper does not introspect column names from the statement itself).
    /// A column whose value is `NULL`/unreadable as text is simply absent
    /// from that row's dictionary, never a fabricated empty string.
    static func query(
        databasePath: String, sql: String, parameters: [String] = [], columns: [String]
    ) throws -> [[String: String]] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else {
            if database != nil { sqlite3_close(database) }
            throw SQLiteError.open
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepare
        }
        defer { sqlite3_finalize(statement) }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, parameter) in parameters.enumerated() {
            guard
                sqlite3_bind_text(
                    statement, Int32(index + 1), parameter, -1, sqliteTransient) == SQLITE_OK
            else {
                throw SQLiteError.bind
            }
        }

        var rows: [[String: String]] = []
        stepping: while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var row: [String: String] = [:]
                for (columnIndex, columnName) in columns.enumerated() {
                    if let text = sqlite3_column_text(statement, Int32(columnIndex)) {
                        row[columnName] = String(cString: text)
                    }
                }
                rows.append(row)
            case SQLITE_DONE:
                break stepping
            default:
                throw SQLiteError.step
            }
        }
        return rows
    }
}
