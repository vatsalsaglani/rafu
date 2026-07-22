import CommonCrypto
import CryptoKit
import Foundation
import SQLite3
import Synchronization
import Testing

@testable import RafuApp

private enum CookieFixtureError: Error {
    case sqlite
    case crypto
}

private final class LockedCounter: Sendable {
    private let storage = Mutex(0)

    func increment() {
        storage.withLock { $0 += 1 }
    }

    func value() -> Int {
        storage.withLock { $0 }
    }
}

private final class ThreadRecorder: Sendable {
    private let storage = Mutex<Bool?>(nil)

    func record(_ value: Bool) {
        storage.withLock { $0 = value }
    }

    func value() -> Bool? {
        storage.withLock { $0 }
    }
}

private final class MemoryCookiePersistence: Sendable {
    private struct State: Sendable {
        var values: [UsageProviderID: String] = [:]
        var loadCount = 0
    }

    private let state = Mutex(State())

    var persistence: CookieHeaderPersistence {
        CookieHeaderPersistence(
            load: { [self] provider in
                state.withLock { state in
                    state.loadCount += 1
                    return state.values[provider]
                }
            },
            store: { [self] header, provider in
                state.withLock { $0.values[provider] = header }
            },
            remove: { [self] provider in
                state.withLock { state in
                    _ = state.values.removeValue(forKey: provider)
                }
            })
    }

    func loadCount() -> Int {
        state.withLock { $0.loadCount }
    }
}

private final class FlakyCookiePersistence: Sendable {
    private struct State: Sendable {
        var loadCount = 0
    }

    private let state = Mutex(State())

    var persistence: CookieHeaderPersistence {
        CookieHeaderPersistence(
            load: { [self] _ in
                let attempt = state.withLock { state in
                    state.loadCount += 1
                    return state.loadCount
                }
                if attempt == 1 {
                    throw CookieHeaderCacheError.keychainFailure(status: errSecNotAvailable)
                }
                return "session=restored-secret"
            },
            store: { _, _ in },
            remove: { _ in })
    }

    func loadCount() -> Int {
        state.withLock { $0.loadCount }
    }
}

private final class InvalidCookiePersistence: Sendable {
    private struct State: Sendable {
        var loadCount = 0
        var removeCount = 0
    }

    private let state = Mutex(State())

    var persistence: CookieHeaderPersistence {
        CookieHeaderPersistence(
            load: { [self] _ in
                state.withLock { $0.loadCount += 1 }
                return "session=invalid\r\nInjected: true"
            },
            store: { _, _ in },
            remove: { [self] _ in
                state.withLock { $0.removeCount += 1 }
            })
    }

    func counts() -> (loads: Int, removals: Int) {
        state.withLock { ($0.loadCount, $0.removeCount) }
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "RafuCookieInfrastructureTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func executeSQLite(_ database: OpaquePointer?, sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw CookieFixtureError.sqlite
    }
}

private struct ChromiumFixtureRow {
    let domain: String
    let name: String
    let path: String
    let expiresUTC: Int64
    let value: String
    let encryptedValue: Data
}

private func createChromiumDatabase(at url: URL, rows: [ChromiumFixtureRow]) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw CookieFixtureError.sqlite }
    defer { sqlite3_close(database) }
    try executeSQLite(
        database,
        sql: """
            CREATE TABLE cookies (
                host_key TEXT NOT NULL,
                name TEXT NOT NULL,
                path TEXT NOT NULL,
                expires_utc INTEGER NOT NULL,
                is_secure INTEGER NOT NULL,
                is_httponly INTEGER NOT NULL,
                value TEXT NOT NULL,
                encrypted_value BLOB NOT NULL
            )
            """)

    let insert = """
        INSERT INTO cookies
        (host_key, name, path, expires_utc, is_secure, is_httponly, value, encrypted_value)
        VALUES (?, ?, ?, ?, 1, 1, ?, ?)
        """
    let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for row in rows {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, insert, -1, &statement, nil) == SQLITE_OK else {
            throw CookieFixtureError.sqlite
        }
        defer { sqlite3_finalize(statement) }
        guard
            row.domain.withCString({ sqlite3_bind_text(statement, 1, $0, -1, sqliteTransient) })
                == SQLITE_OK,
            row.name.withCString({ sqlite3_bind_text(statement, 2, $0, -1, sqliteTransient) })
                == SQLITE_OK,
            row.path.withCString({ sqlite3_bind_text(statement, 3, $0, -1, sqliteTransient) })
                == SQLITE_OK,
            sqlite3_bind_int64(statement, 4, row.expiresUTC) == SQLITE_OK,
            row.value.withCString({ sqlite3_bind_text(statement, 5, $0, -1, sqliteTransient) })
                == SQLITE_OK,
            row.encryptedValue.withUnsafeBytes({ bytes in
                sqlite3_bind_blob(
                    statement, 6, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
            }) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_DONE
        else { throw CookieFixtureError.sqlite }
    }
}

private func createFirefoxDatabase(at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw CookieFixtureError.sqlite }
    defer { sqlite3_close(database) }
    try executeSQLite(
        database,
        sql: """
            CREATE TABLE moz_cookies (
                host TEXT NOT NULL,
                name TEXT NOT NULL,
                path TEXT NOT NULL,
                value TEXT NOT NULL,
                expiry INTEGER NOT NULL,
                isSecure INTEGER NOT NULL,
                isHttpOnly INTEGER NOT NULL
            );
            INSERT INTO moz_cookies VALUES
                ('.example.com', 'session', '/', 'firefox-secret', 2000000000, 1, 1),
                ('example.com.attacker.test', 'session', '/', 'decoy-secret', 2000000000, 1, 1);
            """)
}

private func chromiumExpiry(unixTime: TimeInterval) -> Int64 {
    Int64((unixTime + 11_644_473_600) * 1_000_000)
}

private func encryptedChromiumValue(
    prefix: String,
    hostKey: String,
    value: String,
    key: Data
) throws -> Data {
    var plaintext = Data(SHA256.hash(data: Data(hostKey.utf8)))
    plaintext.append(Data(value.utf8))
    let initializationVector = Data(repeating: 0x20, count: kCCBlockSizeAES128)
    var encrypted = Data(count: plaintext.count + kCCBlockSizeAES128)
    var encryptedLength: size_t = 0
    let encryptedCapacity = encrypted.count
    let status = encrypted.withUnsafeMutableBytes { encryptedBytes in
        plaintext.withUnsafeBytes { plaintextBytes in
            key.withUnsafeBytes { keyBytes in
                initializationVector.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        ivBytes.baseAddress,
                        plaintextBytes.baseAddress,
                        plaintext.count,
                        encryptedBytes.baseAddress,
                        encryptedCapacity,
                        &encryptedLength)
                }
            }
        }
    }
    guard status == kCCSuccess else { throw CookieFixtureError.crypto }
    encrypted.count = encryptedLength
    return Data(prefix.utf8) + encrypted
}

private struct SafariFixtureCookie {
    let domain: String
    let name: String
    let value: String
}

private func safariBinaryCookies(_ cookies: [SafariFixtureCookie]) -> Data {
    let records = cookies.map(safariCookieRecord)
    let pageHeaderSize = 8 + records.count * 4
    var page = Data()
    appendUInt32LE(0, to: &page)
    appendUInt32LE(UInt32(records.count), to: &page)
    var offset = pageHeaderSize
    for record in records {
        appendUInt32LE(UInt32(offset), to: &page)
        offset += record.count
    }
    for record in records { page.append(record) }

    var file = Data("cook".utf8)
    appendUInt32BE(1, to: &file)
    appendUInt32BE(UInt32(page.count), to: &file)
    file.append(page)
    return file
}

private func safariCookieRecord(_ cookie: SafariFixtureCookie) -> Data {
    let headerSize = 56
    let path = "/"
    let domainOffset = headerSize
    let nameOffset = domainOffset + cookie.domain.utf8.count + 1
    let pathOffset = nameOffset + cookie.name.utf8.count + 1
    let valueOffset = pathOffset + path.utf8.count + 1
    let recordSize = valueOffset + cookie.value.utf8.count + 1

    var record = Data()
    appendUInt32LE(UInt32(recordSize), to: &record)
    appendUInt32LE(0, to: &record)
    appendUInt32LE(0x5, to: &record)
    appendUInt32LE(0, to: &record)
    appendUInt32LE(UInt32(domainOffset), to: &record)
    appendUInt32LE(UInt32(nameOffset), to: &record)
    appendUInt32LE(UInt32(pathOffset), to: &record)
    appendUInt32LE(UInt32(valueOffset), to: &record)
    appendUInt32LE(0, to: &record)
    appendUInt32LE(0, to: &record)
    appendDoubleLE(0, to: &record)
    appendDoubleLE(0, to: &record)
    appendCString(cookie.domain, to: &record)
    appendCString(cookie.name, to: &record)
    appendCString(path, to: &record)
    appendCString(cookie.value, to: &record)
    return record
}

private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(contentsOf: [
        UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
    ])
}

private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
    data.append(contentsOf: [
        UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
    ])
}

private func appendDoubleLE(_ value: Double, to data: inout Data) {
    let bits = value.bitPattern
    data.append(contentsOf: (0..<8).map { UInt8((bits >> UInt64($0 * 8)) & 0xFF) })
}

private func appendCString(_ value: String, to data: inout Data) {
    data.append(Data(value.utf8))
    data.append(0)
}

@Test("Chromium reader uses a fixture SQLite store, bound domain/name filters, and injected key")
func chromiumFixtureStoreParsing() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let key = Data(repeating: 0x31, count: kCCKeySizeAES128)
    let database = home.appending(
        path: "Library/Application Support/Google/Chrome/Default/Network/Cookies")
    let v10 = try encryptedChromiumValue(
        prefix: "v10", hostKey: ".example.com", value: "v10-secret", key: key)
    let v11 = try encryptedChromiumValue(
        prefix: "v11", hostKey: ".example.com", value: "v11-secret", key: key)
    try createChromiumDatabase(
        at: database,
        rows: [
            ChromiumFixtureRow(
                domain: ".example.com", name: "session", path: "/",
                expiresUTC: chromiumExpiry(unixTime: 1_900_000_000), value: "",
                encryptedValue: v10),
            ChromiumFixtureRow(
                domain: ".example.com", name: "refresh", path: "/",
                expiresUTC: chromiumExpiry(unixTime: 1_900_000_000), value: "",
                encryptedValue: v11),
            ChromiumFixtureRow(
                domain: ".example.com", name: "plain", path: "/",
                expiresUTC: chromiumExpiry(unixTime: 1_900_000_000), value: "plain-value",
                encryptedValue: Data()),
            ChromiumFixtureRow(
                domain: "example.com.attacker.test", name: "session", path: "/",
                expiresUTC: chromiumExpiry(unixTime: 1_900_000_000), value: "decoy-secret",
                encryptedValue: Data()),
            ChromiumFixtureRow(
                domain: ".example.com", name: "expired", path: "/",
                expiresUTC: chromiumExpiry(unixTime: 1_600_000_000), value: "expired-secret",
                encryptedValue: Data()),
        ])

    let keyReads = LockedCounter()
    let reader = ChromiumCookieReader(
        homeDirectory: home,
        keyProvider: { _ in
            keyReads.increment()
            return key
        })
    let request = try #require(
        CookieReadRequest(
            domains: ["example.com"],
            names: ["session", "refresh", "plain"],
            referenceDate: now))
    let records = try reader.readCookies(for: .chrome, request: request)
    let values = Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0.value) })

    #expect(
        values == [
            "plain": "plain-value",
            "refresh": "v11-secret",
            "session": "v10-secret",
        ])
    #expect(!records.contains(where: { $0.value == "decoy-secret" }))
    #expect(keyReads.value() == 1)
}

@Test("Chromium v10 and v11 decrypt round-trip with an injected derived key")
func chromiumDecryptionRoundTrip() throws {
    let key = try ChromiumCookieReader.deriveKey(from: "fixture-password")
    for prefix in ["v10", "v11"] {
        let encrypted = try encryptedChromiumValue(
            prefix: prefix,
            hostKey: ".example.com",
            value: "secret-for-\(prefix)",
            key: key)
        #expect(
            ChromiumCookieReader.decryptChromiumValue(
                encrypted, hostKey: ".example.com", key: key) == "secret-for-\(prefix)")
    }
    let unknown = Data("v20".utf8) + Data(repeating: 0, count: 16)
    #expect(
        ChromiumCookieReader.decryptChromiumValue(
            unknown, hostKey: ".example.com", key: key) == nil)
}

@Test("Safari binarycookies fixture is bounded and domain/name scoped")
func safariBinaryCookiesParsing() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = home.appending(path: "Cookies.binarycookies")
    let fixture = safariBinaryCookies([
        SafariFixtureCookie(domain: ".example.com", name: "session", value: "safari-secret"),
        SafariFixtureCookie(
            domain: "example.com.attacker.test", name: "session", value: "decoy-secret"),
        SafariFixtureCookie(domain: ".example.com", name: "ignored", value: "ignored-secret"),
    ])
    try fixture.write(to: file)
    let request = try #require(
        CookieReadRequest(
            domains: ["example.com"], names: ["session"], referenceDate: Date()))
    let reader = SafariCookieReader(candidateFiles: [file])
    let records = try reader.readCookies(request: request)

    #expect(records.map(\.value) == ["safari-secret"])
    #expect(records.first?.isSecure == true)
    #expect(records.first?.isHTTPOnly == true)
    #expect(throws: BrowserCookieReadError.self) {
        try SafariCookieReader.parseBinaryCookies(Data(fixture.prefix(11)), request: request)
    }
}

@Test("Safari continues from an empty legacy store to the container store")
func safariCandidateFallback() throws {
    let legacy = URL(fileURLWithPath: "/fixture/legacy.binarycookies")
    let container = URL(fileURLWithPath: "/fixture/container.binarycookies")
    let request = try #require(
        CookieReadRequest(
            domains: ["example.com"], names: ["session"], referenceDate: Date()))
    let reader = SafariCookieReader(
        candidateFiles: [legacy, container],
        dataLoader: { url in
            if url == legacy {
                return safariBinaryCookies([
                    SafariFixtureCookie(
                        domain: ".unrelated.test", name: "session", value: "decoy-secret")
                ])
            }
            return safariBinaryCookies([
                SafariFixtureCookie(
                    domain: ".example.com", name: "session", value: "container-secret")
            ])
        })

    #expect(try reader.readCookies(request: request).map(\.value) == ["container-secret"])
}

@Test("Safari permission denial stays typed and the gate prevents prompt loops")
func safariFullDiskAccessAndBackoff() async throws {
    let reads = LockedCounter()
    let safari = SafariCookieReader(
        candidateFiles: [URL(fileURLWithPath: "/fixture/Cookies.binarycookies")],
        dataLoader: { _ in
            reads.increment()
            throw CocoaError(.fileReadNoPermission)
        })
    let gate = CookieAccessGate(policy: CookieAccessPolicy(failureThreshold: 3, cooldown: 60))
    let reader: BrowserCookieImporter.Reader = { browser, request in
        guard browser == .safari else { throw BrowserCookieReadError.noStore }
        return try safari.readCookies(request: request)
    }

    for _ in 0..<3 {
        let importer = BrowserCookieImporter(testingAccessGate: gate, reader: reader)
        let outcome = await importer.importCookieHeaderOutcome(
            domains: ["example.com"], names: ["session"], browsers: [.safari])
        guard case .needsFullDiskAccess = outcome else {
            Issue.record("expected typed Full Disk Access result")
            return
        }
    }
    let importer = BrowserCookieImporter(testingAccessGate: gate, reader: reader)
    let backedOff = await importer.importCookieHeaderOutcome(
        domains: ["example.com"], names: ["session"], browsers: [.safari])
    guard case .needsFullDiskAccess(let attempts) = backedOff else {
        Issue.record("expected remembered Full Disk Access result during backoff")
        return
    }
    #expect(reads.value() == 3)
    #expect(
        attempts.contains { attempt in
            if case .backedOff(_, let lastFailure) = attempt.status {
                return lastFailure == .needsFullDiskAccess
            }
            return false
        })
}

@Test("Firefox moz_cookies fixture adapts cleanly without Keychain access")
func firefoxFixtureStoreParsing() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let database = home.appending(
        path: "Library/Application Support/Firefox/Profiles/release.default-release/cookies.sqlite")
    try createFirefoxDatabase(at: database)
    let request = try #require(
        CookieReadRequest(
            domains: ["example.com"], names: ["session"],
            referenceDate: Date(timeIntervalSince1970: 1_700_000_000)))

    let records = try FirefoxCookieReader(homeDirectory: home).readCookies(request: request)
    #expect(records.map(\.value) == ["firefox-secret"])
}

@Test("Access gate backs off per browser, expires deterministically, and resets on success")
func accessGateBackoff() async {
    let gate = CookieAccessGate(policy: CookieAccessPolicy(failureThreshold: 2, cooldown: 60))
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(await gate.beginAttempt(for: .chrome, now: now) == .allowed)
    #expect(await gate.beginAttempt(for: .chrome, now: now) == .importAlreadyInProgress)
    await gate.recordFailure(.keychainDenied, for: .chrome, now: now)
    #expect(await gate.beginAttempt(for: .chrome, now: now) == .allowed)
    await gate.recordFailure(.keychainDenied, for: .chrome, now: now)
    #expect(await gate.beginAttempt(for: .brave, now: now) == .allowed)
    await gate.cancelAttempt(for: .brave)
    #expect(
        await gate.beginAttempt(for: .chrome, now: now)
            == .backedOff(
                until: now.addingTimeInterval(60), lastFailure: .keychainDenied))
    #expect(await gate.beginAttempt(for: .chrome, now: now.addingTimeInterval(61)) == .allowed)
    await gate.recordFailure(.unreadableStore, for: .chrome, now: now.addingTimeInterval(61))
    #expect(await gate.beginAttempt(for: .chrome, now: now.addingTimeInterval(61)) == .allowed)
    await gate.recordSuccess(for: .chrome)
    #expect(await gate.beginAttempt(for: .chrome, now: now.addingTimeInterval(61)) == .allowed)
    await gate.cancelAttempt(for: .chrome)
}

@Test("Cookie cache round-trips through injected persistence and memoizes reads")
func cookieCacheRoundTrip() async throws {
    let memory = MemoryCookiePersistence()
    let first = CookieHeaderCache(persistence: memory.persistence)
    try await first.store("session=cache-secret", for: .qoder)
    #expect(first.header(for: .qoder) == "session=cache-secret")
    #expect(memory.loadCount() == 0)

    let restored = CookieHeaderCache(persistence: memory.persistence)
    #expect(restored.header(for: .qoder) == "session=cache-secret")
    #expect(restored.header(for: .qoder) == "session=cache-secret")
    #expect(memory.loadCount() == 1)
    try await restored.remove(for: .qoder)
    #expect(restored.header(for: .qoder) == nil)
    #expect(CookieHeaderPersistence.serviceName(for: .qoder) == "rafu.usage.cookie.qoder")
}

@Test("Cookie cache retries a transient Keychain load instead of memoizing absence")
func cookieCacheRetriesTransientLoadFailure() {
    let flaky = FlakyCookiePersistence()
    let cache = CookieHeaderCache(persistence: flaky.persistence)

    #expect(cache.header(for: .qoder) == nil)
    #expect(cache.header(for: .qoder) == "session=restored-secret")
    #expect(flaky.loadCount() == 2)
}

@Test("Cookie cache removes invalid persisted credentials and memoizes authoritative absence")
func cookieCacheRemovesInvalidPersistedHeader() {
    let invalid = InvalidCookiePersistence()
    let cache = CookieHeaderCache(persistence: invalid.persistence)

    #expect(cache.header(for: .qoder) == nil)
    #expect(cache.header(for: .qoder) == nil)
    let counts = invalid.counts()
    #expect(counts.loads == 1)
    #expect(counts.removals == 1)
}

@Test("Cookie cache rejects header injection and oversize credentials")
func cookieCacheValidation() async {
    let memory = MemoryCookiePersistence()
    let cache = CookieHeaderCache(persistence: memory.persistence)
    await #expect(throws: CookieHeaderCacheError.invalidHeader) {
        try await cache.store("session=secret\r\nInjected: true", for: .qoder)
    }
    await #expect(throws: CookieHeaderCacheError.invalidHeader) {
        try await cache.store(
            String(repeating: "x", count: CookieHeaderCache.maximumHeaderBytes + 1),
            for: .qoder)
    }
}

@MainActor
@Test("Importer offloads its synchronous reader and returns the exact convenience header")
func importerRunsOffMain() async {
    let thread = ThreadRecorder()
    let importer = BrowserCookieImporter(reader: { _, _ in
        thread.record(Thread.isMainThread)
        return [
            BrowserCookieRecord(
                domain: ".example.com",
                name: "session",
                path: "/",
                value: "import-secret",
                expires: nil,
                isSecure: true,
                isHTTPOnly: true)
        ]
    })
    let header = await importer.importCookieHeader(
        domains: ["example.com"], names: ["session"], browsers: [.chrome])
    #expect(header == "session=import-secret")
    #expect(thread.value() == false)
}

@Test("A browser importer authorizes exactly one explicit import call")
func importerAuthorizationIsOneShot() async {
    let reads = LockedCounter()
    let importer = BrowserCookieImporter(reader: { _, _ in
        reads.increment()
        return [
            BrowserCookieRecord(
                domain: ".example.com", name: "session", path: "/", value: "secret",
                expires: nil, isSecure: true, isHTTPOnly: true)
        ]
    })

    let first = await importer.importCookieHeaderOutcome(
        domains: ["example.com"], names: ["session"], browsers: [.chrome])
    guard case .imported = first else {
        Issue.record("expected the authorized import to succeed")
        return
    }
    #expect(
        await importer.importCookieHeaderOutcome(
            domains: ["example.com"], names: ["session"], browsers: [.chrome])
            == .authorizationRequired)
    #expect(reads.value() == 1)
}

@Test("Importer releases its browser attempt and never publishes after reader cancellation")
func importerCancellationAfterRead() async {
    let gate = CookieAccessGate()
    let importer = BrowserCookieImporter(
        testingAccessGate: gate,
        reader: { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return [
                BrowserCookieRecord(
                    domain: ".example.com", name: "session", path: "/", value: "secret",
                    expires: nil, isSecure: true, isHTTPOnly: true)
            ]
        })
    let task = Task {
        await importer.importCookieHeaderOutcome(
            domains: ["example.com"], names: ["session"], browsers: [.chrome])
    }

    #expect(await task.value == .cancelled)

    let retry = BrowserCookieImporter(testingAccessGate: gate, reader: { _, _ in [] })
    #expect(
        await retry.importCookieHeaderOutcome(
            domains: ["example.com"], names: ["session"], browsers: [.chrome])
            == .noMatchingCookies(
                attempts: [
                    BrowserCookieAttempt(browser: .chrome, status: .noMatchingCookies)
                ]))
}

@Test("Cancelled reader errors release the attempt without poisoning browser backoff")
func importerCancellationDoesNotRecordFailure() async {
    let gate = CookieAccessGate(policy: CookieAccessPolicy(failureThreshold: 1, cooldown: 60))
    let importer = BrowserCookieImporter(
        testingAccessGate: gate,
        reader: { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            throw BrowserCookieReadError.invalidStore
        })
    let task = Task {
        await importer.importCookieHeaderOutcome(
            domains: ["example.com"], names: ["session"], browsers: [.chrome])
    }

    #expect(await task.value == .cancelled)

    let retry = BrowserCookieImporter(testingAccessGate: gate, reader: { _, _ in [] })
    #expect(
        await retry.importCookieHeaderOutcome(
            domains: ["example.com"], names: ["session"], browsers: [.chrome])
            == .noMatchingCookies(
                attempts: [
                    BrowserCookieAttempt(browser: .chrome, status: .noMatchingCookies)
                ]))
}

@Test("Cookie outcomes and errors redact credential sentinels")
func cookieInfrastructureRedaction() {
    let secret = "cookie-super-secret-sentinel"
    let outcome = BrowserCookieImportOutcome.imported(
        ImportedCookieHeader(
            browser: .chrome, rawValue: "session=\(secret)"))
    let diagnostics = [
        String(describing: outcome),
        String(reflecting: outcome),
        BrowserCookieReadError.keychainDenied.description,
        BrowserCookieReadError.needsFullDiskAccess.description,
        CookieHeaderCacheError.invalidHeader.description,
        CookieHeaderCacheError.keychainFailure(status: errSecAuthFailed).description,
    ]
    for diagnostic in diagnostics {
        #expect(!diagnostic.contains(secret))
        #expect(!diagnostic.lowercased().contains("session="))
    }
}

@Test("Empty domains and empty explicit names cannot widen into a full cookie-jar read")
func importerRejectsUnscopedRequests() async {
    let reads = LockedCounter()
    let importer = BrowserCookieImporter(reader: { _, _ in
        reads.increment()
        return []
    })
    #expect(
        await importer.importCookieHeader(
            domains: [], names: nil, browsers: [.chrome]) == nil)
    #expect(
        await importer.importCookieHeader(
            domains: ["example.com"], names: [], browsers: [.chrome]) == nil)
    #expect(reads.value() == 0)
}
