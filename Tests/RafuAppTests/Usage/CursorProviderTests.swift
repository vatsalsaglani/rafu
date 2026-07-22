import Foundation
import SQLite3
import Testing

@testable import RafuApp

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private func cursorContext(
    now: Date = Date(), http: UsageHTTPClient = .noop
) -> UsageFetchContext {
    UsageFetchContext(
        now: now, readFile: { _ in nil }, http: http, credential: { _ in nil },
        cookieHeader: { _ in nil })
}

private func syntheticCursorJWT(subject: String) throws -> String {
    func base64URL(_ object: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let header = try base64URL(["alg": "none"])
    let payload = try base64URL(["sub": subject])
    return "\(header).\(payload).signature"
}

private func makeCursorDatabase(token: String?) throws -> (root: URL, database: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CursorProviderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = root.appendingPathComponent("state.vscdb")

    var db: OpaquePointer?
    guard sqlite3_open(database.path, &db) == SQLITE_OK else {
        throw CursorFixtureError.open
    }
    defer { sqlite3_close(db) }
    guard
        sqlite3_exec(
            db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);", nil, nil, nil)
            == SQLITE_OK
    else {
        throw CursorFixtureError.exec
    }

    if let token {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db, "INSERT INTO ItemTable (key, value) VALUES (?, ?);", -1, &statement, nil)
                == SQLITE_OK
        else {
            throw CursorFixtureError.prepare
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, "cursorAuth/accessToken", -1, transient)
        sqlite3_bind_text(statement, 2, token, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CursorFixtureError.step }
    }
    return (root, database)
}

private enum CursorFixtureError: Error {
    case open, exec, prepare, step
}

@Test("Cursor JWT sub becomes the CodexBar-compatible synthesized session cookie")
func cursorJWTDecodingAndCookieSynthesis() throws {
    let token = try syntheticCursorJWT(subject: "workos|user_123")
    #expect(try CursorVSCDBStrategy.userID(accessToken: token) == "user_123")
    #expect(
        try CursorVSCDBStrategy.cookieHeader(accessToken: token)
            == "WorkosCursorSessionToken=user_123%3A%3A\(token)")
}

@Test("Cursor state.vscdb fixture maps usage-summary, reset, on-demand spend, and identity")
func cursorSQLiteAndResponseMapping() async throws {
    let token = try syntheticCursorJWT(subject: "auth0|fixture-user")
    let fixture = try makeCursorDatabase(token: token)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let expectedCookie = "WorkosCursorSessionToken=fixture-user%3A%3A\(token)"

    let client = UsageHTTPClient(transport: { request in
        #expect(request.value(forHTTPHeaderField: "Cookie") == expectedCookie)
        let body: Data
        switch request.url?.path {
        case "/api/usage-summary":
            body = Data(
                """
                {
                  "billingCycleEnd": "2026-08-01T00:00:00.000Z",
                  "membershipType": "pro",
                  "individualUsage": {
                    "plan": {"used": 1875, "limit": 5000, "totalPercentUsed": 37.5},
                    "onDemand": {"used": 320, "limit": 5000}
                  }
                }
                """.utf8)
        case "/api/auth/me":
            body = Data(#"{"email":"cursor@example.com","sub":"fixture-user"}"#.utf8)
        default:
            throw UsageHTTPError.invalidResponse
        }
        let response = try #require(
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (body, response)
    })
    let strategy = CursorVSCDBStrategy(
        databasePath: fixture.database.path,
        baseURL: try #require(URL(string: "https://cursor.test")))
    let snapshot = try await strategy.fetch(cursorContext(http: client))

    #expect(snapshot.providerID == .cursor)
    #expect(
        snapshot.windows == [
            UsageWindow(
                label: "monthly", percent: 37.5, tokens: nil,
                resetsAt: UsageDateParsing.parseISO8601Fractional("2026-08-01T00:00:00.000Z"))
        ])
    #expect(snapshot.costLine == "$3.20 of $50.00 on demand")
    #expect(snapshot.identity == "cursor@example.com")
}

@Test("Cursor missing database or absent access-token row hides the snapshot")
func cursorMissingLocalAuthReturnsNil() async throws {
    let missing = CursorVSCDBStrategy(
        databasePath: "/tmp/CursorProviderTests-\(UUID().uuidString)/missing.vscdb")
    #expect(
        await resolveUsageSnapshot(
            strategies: [missing], context: cursorContext()) == nil)

    let fixture = try makeCursorDatabase(token: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let noToken = CursorVSCDBStrategy(databasePath: fixture.database.path)
    #expect(
        await resolveUsageSnapshot(
            strategies: [noToken], context: cursorContext()) == nil)
}

@Test("Cursor transport failures cannot expose the synthesized cookie or token")
func cursorCookieIsRedactedFromErrors() async throws {
    let token = try syntheticCursorJWT(subject: "auth0|redaction-user")
    let fixture = try makeCursorDatabase(token: token)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let client = UsageHTTPClient(transport: { _ in
        throw NSError(domain: token, code: 1)
    })
    let strategy = CursorVSCDBStrategy(databasePath: fixture.database.path)

    do {
        _ = try await strategy.fetch(cursorContext(http: client))
        Issue.record("expected the redacting HTTP client to throw")
    } catch {
        let text = String(describing: error)
        #expect(!text.contains(token))
        #expect(!text.contains("WorkosCursorSessionToken"))
    }
}

@Test("Cursor descriptor is opt-in and strategy count does not depend on context")
func cursorDescriptorContract() {
    let probe = cursorContext()
    let populated = UsageFetchContext(
        now: Date(), readFile: { _ in "fixture" }, http: .noop,
        credential: { _ in "secret" }, cookieHeader: { _ in "cookie" })
    #expect(CursorProvider.descriptor.makeStrategies(probe).count == 1)
    #expect(CursorProvider.descriptor.makeStrategies(populated).count == 1)
    #expect(CursorProvider.descriptor.defaultEnabled == false)
    if case .piggybackNetwork = CursorProvider.descriptor.authPattern {
        // Expected.
    } else {
        Issue.record("Cursor must remain a piggyback-network provider")
    }
}
