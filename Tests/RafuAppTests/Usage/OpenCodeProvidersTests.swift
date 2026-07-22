import Foundation
import SQLite3
import Testing

@testable import RafuApp

private struct OpenCodeFixture {
    let root: URL
    let database: URL
}

private enum OpenCodeFixtureError: Error {
    case open, exec, prepare, step
}

private func openCodeDate(_ iso: String) -> Date {
    UsageDateParsing.parseISO8601Fractional(iso) ?? .distantPast
}

private func openCodeMilliseconds(_ iso: String) -> Int64 {
    Int64(openCodeDate(iso).timeIntervalSince1970 * 1_000)
}

private func openCodeContext(
    now: Date, auth: String?
) -> UsageFetchContext {
    UsageFetchContext(
        now: now,
        readFile: { path in
            path == OpenCodeLocalUsageStrategy.defaultAuthPath ? auth : nil
        },
        http: .noop, credential: { _ in nil }, cookieHeader: { _ in nil })
}

private func makeOpenCodeDatabase(includePartTable: Bool = true) throws -> OpenCodeFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("OpenCodeProvidersTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = root.appendingPathComponent("opencode.db")
    var db: OpaquePointer?
    guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw OpenCodeFixtureError.open }
    defer { sqlite3_close(db) }

    var schema = """
        CREATE TABLE message (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          data TEXT NOT NULL,
          time_created INTEGER,
          time_updated INTEGER
        );
        """
    if includePartTable {
        schema += """

            CREATE TABLE part (
              id TEXT PRIMARY KEY,
              message_id TEXT NOT NULL,
              session_id TEXT NOT NULL,
              data TEXT NOT NULL,
              time_created INTEGER,
              time_updated INTEGER
            );
            """
    }
    guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
        throw OpenCodeFixtureError.exec
    }
    return OpenCodeFixture(root: root, database: database)
}

@discardableResult
private func insertOpenCodeMessage(
    into database: URL,
    providerID: String,
    role: String = "assistant",
    createdMs: Int64,
    cost: Double?
) throws -> String {
    var db: OpaquePointer?
    guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw OpenCodeFixtureError.open }
    defer { sqlite3_close(db) }
    let messageID = UUID().uuidString
    var payload: [String: Any] = [
        "providerID": providerID,
        "role": role,
        "time": ["created": createdMs],
        // Deliberately ignored content proves the production SQL projects
        // only metric fields rather than parsing message text.
        "content": "fixture content that must never be read",
    ]
    if let cost { payload["cost"] = cost }
    let json =
        String(
            data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"

    var statement: OpaquePointer?
    guard
        sqlite3_prepare_v2(
            db,
            "INSERT INTO message (id, session_id, data, time_created, time_updated) VALUES (?, ?, ?, ?, ?);",
            -1, &statement, nil) == SQLITE_OK
    else {
        throw OpenCodeFixtureError.prepare
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, messageID, -1, transient)
    sqlite3_bind_text(statement, 2, "session-1", -1, transient)
    sqlite3_bind_text(statement, 3, json, -1, transient)
    sqlite3_bind_int64(statement, 4, createdMs)
    sqlite3_bind_int64(statement, 5, createdMs)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw OpenCodeFixtureError.step }
    return messageID
}

private func insertOpenCodePart(
    into database: URL, messageID: String, createdMs: Int64, cost: Double
) throws {
    var db: OpaquePointer?
    guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw OpenCodeFixtureError.open }
    defer { sqlite3_close(db) }
    let payload: [String: Any] = [
        "type": "step-finish",
        "cost": cost,
        "tokens": ["input": 1, "output": 1],
    ]
    let json =
        String(
            data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"

    var statement: OpaquePointer?
    guard
        sqlite3_prepare_v2(
            db,
            "INSERT INTO part (id, message_id, session_id, data, time_created, time_updated) VALUES (?, ?, ?, ?, ?, ?);",
            -1, &statement, nil) == SQLITE_OK
    else {
        throw OpenCodeFixtureError.prepare
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, UUID().uuidString, -1, transient)
    sqlite3_bind_text(statement, 2, messageID, -1, transient)
    sqlite3_bind_text(statement, 3, "session-1", -1, transient)
    sqlite3_bind_text(statement, 4, json, -1, transient)
    sqlite3_bind_int64(statement, 5, createdMs)
    sqlite3_bind_int64(statement, 6, createdMs)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw OpenCodeFixtureError.step }
}

@Test("OpenCode and OpenCode Go de-duplicate message/part costs and keep provider rows separate")
func openCodeSQLiteWindowsAndProviderFiltering() async throws {
    let fixture = try makeOpenCodeDatabase()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let now = openCodeDate("2026-03-06T12:00:00.000Z")

    let openCodeMessage = try insertOpenCodeMessage(
        into: fixture.database, providerID: "anthropic",
        createdMs: openCodeMilliseconds("2026-03-06T11:00:00.000Z"), cost: 9)
    try insertOpenCodePart(
        into: fixture.database, messageID: openCodeMessage,
        createdMs: openCodeMilliseconds("2026-03-06T11:00:00.000Z"), cost: 1)
    try insertOpenCodePart(
        into: fixture.database, messageID: openCodeMessage,
        createdMs: openCodeMilliseconds("2026-03-06T11:05:00.000Z"), cost: 2)

    _ = try insertOpenCodeMessage(
        into: fixture.database, providerID: "opencode-go",
        createdMs: openCodeMilliseconds("2026-03-06T10:00:00.000Z"), cost: 6)
    _ = try insertOpenCodeMessage(
        into: fixture.database, providerID: "anthropic", role: "user",
        createdMs: openCodeMilliseconds("2026-03-06T11:30:00.000Z"), cost: 99)

    let auth =
        #"{"anthropic":{"type":"api-key","key":"a"},"opencode-go":{"type":"api-key","key":"g"}}"#
    let context = openCodeContext(now: now, auth: auth)
    let openCode = OpenCodeLocalUsageStrategy(databasePath: fixture.database.path)
    let go = OpenCodeLocalUsageStrategy(
        providerID: .openCodeGo, scope: .openCodeGo, databasePath: fixture.database.path)

    let openCodeSnapshot = try await openCode.fetch(context)
    #expect(openCodeSnapshot.providerID == .openCode)
    #expect(openCodeSnapshot.windows.map(\.percent) == [25, 10, 5])
    #expect(openCodeSnapshot.costLine == "$3.00 of $12 (5h)")
    #expect(
        openCodeSnapshot.windows[0].resetsAt
            == openCodeDate("2026-03-06T16:00:00.000Z"))
    #expect(
        openCodeSnapshot.windows[1].resetsAt
            == openCodeDate("2026-03-09T00:00:00.000Z"))
    #expect(
        openCodeSnapshot.windows[2].resetsAt
            == openCodeDate("2026-04-06T11:00:00.000Z"))

    let goSnapshot = try await go.fetch(context)
    #expect(goSnapshot.providerID == .openCodeGo)
    #expect(goSnapshot.windows.map(\.percent) == [50, 20, 10])
    #expect(goSnapshot.costLine == "$6.00 of $12 (5h)")
}

@Test("OpenCode message-only schema falls back to the assistant message cost")
func openCodeMessageOnlyDatabase() async throws {
    let fixture = try makeOpenCodeDatabase(includePartTable: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let now = openCodeDate("2026-03-06T12:00:00.000Z")
    _ = try insertOpenCodeMessage(
        into: fixture.database, providerID: "openai",
        createdMs: openCodeMilliseconds("2026-03-06T11:00:00.000Z"), cost: 1.2)
    let strategy = OpenCodeLocalUsageStrategy(databasePath: fixture.database.path)
    let snapshot = try await strategy.fetch(
        openCodeContext(now: now, auth: #"{"openai":{"key":"fixture"}}"#))

    #expect(snapshot.windows.map(\.percent) == [10, 4, 2])
    #expect(snapshot.costLine == "$1.20 of $12 (5h)")
}

@Test("OpenCode providers hide missing databases and absent or wrong auth")
func openCodeMissingDatabaseOrAuthReturnsNil() async throws {
    let now = openCodeDate("2026-03-06T12:00:00.000Z")
    let missing = OpenCodeLocalUsageStrategy(
        databasePath: "/tmp/OpenCodeProvidersTests-\(UUID().uuidString)/missing.db")
    #expect(
        await resolveUsageSnapshot(
            strategies: [missing],
            context: openCodeContext(now: now, auth: #"{"openai":{"key":"x"}}"#)) == nil)

    let fixture = try makeOpenCodeDatabase()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try insertOpenCodeMessage(
        into: fixture.database, providerID: "opencode-go",
        createdMs: openCodeMilliseconds("2026-03-06T11:00:00.000Z"), cost: 1)
    let go = OpenCodeLocalUsageStrategy(
        providerID: .openCodeGo, scope: .openCodeGo, databasePath: fixture.database.path)
    #expect(
        await resolveUsageSnapshot(
            strategies: [go], context: openCodeContext(now: now, auth: nil)) == nil)
    #expect(
        await resolveUsageSnapshot(
            strategies: [go],
            context: openCodeContext(now: now, auth: #"{"openai":{"key":"x"}}"#)) == nil)
}

@Test("OpenCode descriptors are default-on and strategy counts are context-invariant")
func openCodeDescriptorContracts() {
    let empty = openCodeContext(now: Date(), auth: nil)
    let populated = openCodeContext(
        now: Date(),
        auth: #"{"openai":{"key":"x"},"opencode-go":{"key":"g"}}"#)
    for descriptor in [OpenCodeProvider.descriptor, OpenCodeGoProvider.descriptor] {
        #expect(descriptor.makeStrategies(empty).count == 1)
        #expect(descriptor.makeStrategies(populated).count == 1)
        #expect(descriptor.defaultEnabled == true)
        if case .localZeroConfig = descriptor.authPattern {
            // Expected.
        } else {
            Issue.record("OpenCode SQLite providers must remain local zero-config")
        }
    }
}
