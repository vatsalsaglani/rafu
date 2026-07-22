// Adapted from CodexBar and SweetCookieKit (https://github.com/steipete), MIT License.
// Rafu keeps only the bounded, domain-scoped import shape and implements it
// against the W0 UsageSQLite seam without exposing browser cookie jars.

import Foundation
import Synchronization

/// Browsers W1 can inspect from an explicit Settings action. Chromium
/// variants use their own Safe Storage Keychain item; Firefox and Safari do
/// not. This intentionally stays a small, closed roster for bounded profile
/// discovery and access-gate state.
nonisolated enum Browser: String, CaseIterable, Sendable {
    case chrome, brave, edge, arc, firefox, safari

    var displayName: String {
        switch self {
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .arc: "Arc"
        case .firefox: "Firefox"
        case .safari: "Safari"
        }
    }

    var chromiumProfileRelativePath: String? {
        switch self {
        case .chrome: "Google/Chrome"
        case .brave: "BraveSoftware/Brave-Browser"
        case .edge: "Microsoft Edge"
        case .arc: "Arc/User Data"
        case .firefox, .safari: nil
        }
    }

    var safeStorageLabel: (service: String, account: String)? {
        switch self {
        case .chrome: ("Chrome Safe Storage", "Chrome")
        case .brave: ("Brave Safe Storage", "Brave")
        case .edge: ("Microsoft Edge Safe Storage", "Microsoft Edge")
        case .arc: ("Arc Safe Storage", "Arc")
        case .firefox, .safari: nil
        }
    }
}

/// A credential wrapper whose string/debug representations are always
/// redacted. Only the importer convenience method and cache can reveal the
/// header for an authenticated request or Rafu-owned Keychain persistence.
nonisolated struct ImportedCookieHeader: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let browser: Browser
    let rawValue: String

    var description: String { "<redacted cookie header>" }
    var debugDescription: String { description }
}

nonisolated enum BrowserCookieAccessFailure: String, Equatable, Sendable {
    case needsFullDiskAccess
    case keychainDenied
    case unreadableStore
    case invalidStore
}

nonisolated enum BrowserCookieAccessStatus: Equatable, Sendable {
    case noStore
    case noMatchingCookies
    case importAlreadyInProgress
    case needsFullDiskAccess
    case keychainDenied
    case unreadableStore
    case invalidStore
    case backedOff(until: Date, lastFailure: BrowserCookieAccessFailure)
}

nonisolated struct BrowserCookieAttempt: Equatable, Sendable {
    let browser: Browser
    let status: BrowserCookieAccessStatus
}

/// Settings uses this typed result to render Safari Full Disk Access guidance
/// inline. Its description is deliberately structural and never includes a
/// cookie value.
nonisolated enum BrowserCookieImportOutcome: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    case imported(ImportedCookieHeader)
    case needsFullDiskAccess(attempts: [BrowserCookieAttempt])
    case unavailable(attempts: [BrowserCookieAttempt])
    case noMatchingCookies(attempts: [BrowserCookieAttempt])
    case authorizationRequired
    case invalidRequest
    case cancelled

    var description: String {
        switch self {
        case .imported(let header): "imported(\(header))"
        case .needsFullDiskAccess(let attempts):
            "needsFullDiskAccess(browsers: \(attempts.map(\.browser.rawValue)))"
        case .unavailable(let attempts):
            "unavailable(browsers: \(attempts.map(\.browser.rawValue)))"
        case .noMatchingCookies(let attempts):
            "noMatchingCookies(browsers: \(attempts.map(\.browser.rawValue)))"
        case .authorizationRequired: "authorizationRequired"
        case .invalidRequest: "invalidRequest"
        case .cancelled: "cancelled"
        }
    }

    var debugDescription: String { description }
}

nonisolated enum BrowserCookieReadError: Error, Equatable, Sendable,
    CustomStringConvertible
{
    case noStore
    case needsFullDiskAccess
    case keychainDenied
    case unreadableStore
    case invalidStore

    var description: String {
        switch self {
        case .noStore: "browser cookie store not found"
        case .needsFullDiskAccess: "browser cookie store needs Full Disk Access"
        case .keychainDenied: "browser Safe Storage access denied"
        case .unreadableStore: "browser cookie store unreadable"
        case .invalidStore: "browser cookie store invalid"
        }
    }
}

nonisolated struct BrowserCookieRecord: Equatable, Sendable {
    let domain: String
    let name: String
    let path: String
    let value: String
    let expires: Date?
    let isSecure: Bool
    let isHTTPOnly: Bool
}

/// Validated request shared by all private readers. Empty domains and empty
/// explicit name lists are rejected so no internal query can widen into a
/// full-cookie-jar read.
nonisolated struct CookieReadRequest: Equatable, Sendable {
    static let maximumDomains = 32
    static let maximumNames = 64
    static let maximumRecords = 256
    static let maximumHeaderBytes = 16 * 1_024

    let domains: [String]
    let names: [String]?
    let referenceDate: Date

    init?(domains rawDomains: [String], names rawNames: [String]?, referenceDate: Date) {
        guard !rawDomains.isEmpty, rawDomains.count <= Self.maximumDomains else { return nil }
        var seenDomains = Set<String>()
        let domains = rawDomains.compactMap(Self.normalizeDomain).filter {
            seenDomains.insert($0).inserted
        }
        guard !domains.isEmpty, domains.count == rawDomains.count else { return nil }

        let names: [String]?
        if let rawNames {
            guard !rawNames.isEmpty, rawNames.count <= Self.maximumNames else { return nil }
            var seenNames = Set<String>()
            let validated = rawNames.filter(Self.isValidCookieName).filter {
                seenNames.insert($0).inserted
            }
            guard !validated.isEmpty, validated.count == rawNames.count else { return nil }
            names = validated
        } else {
            names = nil
        }

        self.domains = domains
        self.names = names
        self.referenceDate = referenceDate
    }

    func matches(domain rawDomain: String) -> Bool {
        guard let domain = Self.normalizeDomain(rawDomain) else { return false }
        return domains.contains { domain == $0 || domain.hasSuffix(".\($0)") }
    }

    func matches(name: String) -> Bool {
        names?.contains(name) ?? true
    }

    static func normalizeDomain(_ rawDomain: String) -> String? {
        var domain = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while domain.hasPrefix(".") { domain.removeFirst() }
        while domain.hasSuffix(".") { domain.removeLast() }
        guard !domain.isEmpty, domain.utf8.count <= 253, domain.utf8.allSatisfy({ $0 < 128 }) else {
            return nil
        }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        for label in labels {
            guard !label.isEmpty, label.utf8.count <= 63,
                label.first?.isLetter == true || label.first?.isNumber == true,
                label.last?.isLetter == true || label.last?.isNumber == true,
                label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
            else { return nil }
        }
        return domain
    }

    static func isValidCookieName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 256, name.utf8.allSatisfy({ 0x21...0x7E ~= $0 })
        else { return false }
        let separators = CharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t")
        return name.unicodeScalars.allSatisfy { !separators.contains($0) }
    }

    static func isValidCookieValue(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumHeaderBytes else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && scalar != ";" && scalar != "\r"
                && scalar != "\n" && scalar != "\0"
        }
    }
}

/// Produces a bound SQL predicate only; callers append it to fixed query
/// templates and pass `parameters` to UsageSQLite. Column names are internal
/// constants, never user input.
nonisolated enum CookieSQL {
    static func predicate(
        domainColumn: String, nameColumn: String, request: CookieReadRequest
    ) -> (clause: String, parameters: [String]) {
        let domainClauses = Array(
            repeating: "(LOWER(\(domainColumn)) = ? OR LOWER(\(domainColumn)) = ? "
                + "OR LOWER(\(domainColumn)) LIKE ?)",
            count: request.domains.count)
        var parameters = request.domains.flatMap { [$0, ".\($0)", "%.\($0)"] }
        var clauses = ["(\(domainClauses.joined(separator: " OR ")))"]
        if let names = request.names {
            clauses.append(
                "\(nameColumn) IN (\(Array(repeating: "?", count: names.count).joined(separator: ", ")))"
            )
            parameters.append(contentsOf: names)
        }
        return (clauses.joined(separator: " AND "), parameters)
    }
}

/// The only browser-import entry point. It is intentionally called from a
/// Settings button action: Chromium may display a macOS Keychain consent
/// dialog. Usage refreshes consume CookieHeaderCache only and must never call
/// this importer. `@concurrent` keeps SQLite, Keychain, crypto, and parsing off
/// the caller's actor under Swift 6.2 semantics.
private nonisolated final class CookieImportAuthorization: Sendable {
    private let available = Mutex(true)

    func claim() -> Bool {
        available.withLock { available in
            guard available else { return false }
            available = false
            return true
        }
    }
}

nonisolated struct BrowserCookieImporter: Sendable {
    typealias Reader = @Sendable (Browser, CookieReadRequest) throws -> [BrowserCookieRecord]

    private let accessGate: CookieAccessGate
    private let authorization: CookieImportAuthorization
    private let reader: Reader

    private init(
        accessGate: CookieAccessGate,
        reader: Reader? = nil
    ) {
        self.accessGate = accessGate
        authorization = CookieImportAuthorization()
        if let reader {
            self.reader = reader
        } else {
            let chromium = ChromiumCookieReader()
            let safari = SafariCookieReader()
            let firefox = FirefoxCookieReader()
            self.reader = { browser, request in
                switch browser {
                case .chrome, .brave, .edge, .arc:
                    try chromium.readCookies(for: browser, request: request)
                case .safari:
                    try safari.readCookies(request: request)
                case .firefox:
                    try firefox.readCookies(request: request)
                }
            }
        }
    }

    /// Production construction is main-actor-only so browser access can only
    /// originate from a visible user action. Each value authorizes one import
    /// call; retries require a fresh action and fresh importer.
    @MainActor
    static func userInitiated() -> BrowserCookieImporter {
        BrowserCookieImporter(accessGate: .shared)
    }

    #if DEBUG
        /// Fixture seam only. Tests never read a real browser or Keychain.
        init(
            testingAccessGate accessGate: CookieAccessGate = CookieAccessGate(),
            reader: @escaping Reader
        ) {
            self.init(accessGate: accessGate, reader: reader)
        }
    #endif

    /// Binding W1 API for W6-W8. Typed Settings guidance is available from
    /// `importCookieHeaderOutcome`; every non-success outcome erases to nil.
    @concurrent
    func importCookieHeader(
        domains: [String], names: [String]?, browsers: [Browser]
    ) async -> String? {
        let outcome = await importCookieHeaderOutcome(
            domains: domains, names: names, browsers: browsers)
        guard case .imported(let header) = outcome else { return nil }
        return header.rawValue
    }

    @concurrent
    func importCookieHeaderOutcome(
        domains: [String], names: [String]?, browsers: [Browser]
    ) async -> BrowserCookieImportOutcome {
        guard
            let request = CookieReadRequest(
                domains: domains, names: names, referenceDate: Date()),
            !browsers.isEmpty
        else { return .invalidRequest }
        guard !Task.isCancelled else { return .cancelled }
        guard authorization.claim() else { return .authorizationRequired }

        var seenBrowsers = Set<Browser>()
        let orderedBrowsers = browsers.filter { seenBrowsers.insert($0).inserted }
        var attempts: [BrowserCookieAttempt] = []
        var sawFullDiskAccess = false
        var sawUnavailable = false

        for browser in orderedBrowsers {
            guard !Task.isCancelled else { return .cancelled }
            let accessDecision = await accessGate.beginAttempt(for: browser)
            guard !Task.isCancelled else {
                if accessDecision == .allowed {
                    await accessGate.cancelAttempt(for: browser)
                }
                return .cancelled
            }
            switch accessDecision {
            case .allowed:
                break
            case .importAlreadyInProgress:
                attempts.append(
                    BrowserCookieAttempt(browser: browser, status: .importAlreadyInProgress))
                sawUnavailable = true
                continue
            case .backedOff(let until, let lastFailure):
                attempts.append(
                    BrowserCookieAttempt(
                        browser: browser,
                        status: .backedOff(until: until, lastFailure: lastFailure)))
                sawFullDiskAccess = sawFullDiskAccess || lastFailure == .needsFullDiskAccess
                sawUnavailable = true
                continue
            }

            do {
                let records = try reader(browser, request)
                guard !Task.isCancelled else {
                    await accessGate.cancelAttempt(for: browser)
                    return .cancelled
                }
                await accessGate.recordSuccess(for: browser)
                guard !Task.isCancelled else { return .cancelled }
                guard let header = Self.makeHeader(records: records, request: request) else {
                    attempts.append(
                        BrowserCookieAttempt(browser: browser, status: .noMatchingCookies))
                    continue
                }
                return .imported(ImportedCookieHeader(browser: browser, rawValue: header))
            } catch let error as BrowserCookieReadError {
                guard !Task.isCancelled else {
                    await accessGate.cancelAttempt(for: browser)
                    return .cancelled
                }
                let status: BrowserCookieAccessStatus
                switch error {
                case .noStore:
                    status = .noStore
                    await accessGate.cancelAttempt(for: browser)
                case .needsFullDiskAccess:
                    status = .needsFullDiskAccess
                    sawFullDiskAccess = true
                    sawUnavailable = true
                    await accessGate.recordFailure(.needsFullDiskAccess, for: browser)
                case .keychainDenied:
                    status = .keychainDenied
                    sawUnavailable = true
                    await accessGate.recordFailure(.keychainDenied, for: browser)
                case .unreadableStore:
                    status = .unreadableStore
                    sawUnavailable = true
                    await accessGate.recordFailure(.unreadableStore, for: browser)
                case .invalidStore:
                    status = .invalidStore
                    sawUnavailable = true
                    await accessGate.recordFailure(.invalidStore, for: browser)
                }
                guard !Task.isCancelled else { return .cancelled }
                attempts.append(BrowserCookieAttempt(browser: browser, status: status))
            } catch is CancellationError {
                await accessGate.cancelAttempt(for: browser)
                return .cancelled
            } catch {
                guard !Task.isCancelled else {
                    await accessGate.cancelAttempt(for: browser)
                    return .cancelled
                }
                sawUnavailable = true
                attempts.append(BrowserCookieAttempt(browser: browser, status: .unreadableStore))
                await accessGate.recordFailure(.unreadableStore, for: browser)
                guard !Task.isCancelled else { return .cancelled }
            }
        }

        guard !Task.isCancelled else { return .cancelled }
        if sawFullDiskAccess { return .needsFullDiskAccess(attempts: attempts) }
        if sawUnavailable { return .unavailable(attempts: attempts) }
        return .noMatchingCookies(attempts: attempts)
    }

    private static func makeHeader(
        records: [BrowserCookieRecord], request: CookieReadRequest
    ) -> String? {
        guard records.count <= CookieReadRequest.maximumRecords else { return nil }
        var selectedByName: [String: BrowserCookieRecord] = [:]
        for record in records {
            guard request.matches(domain: record.domain), request.matches(name: record.name),
                record.expires.map({ $0 >= request.referenceDate }) ?? true,
                CookieReadRequest.isValidCookieName(record.name),
                CookieReadRequest.isValidCookieValue(record.value)
            else { continue }
            if let existing = selectedByName[record.name] {
                let shouldReplace =
                    record.path.count > existing.path.count
                    || (record.path.count == existing.path.count
                        && (record.expires ?? .distantFuture) > (existing.expires ?? .distantFuture))
                if shouldReplace { selectedByName[record.name] = record }
            } else {
                selectedByName[record.name] = record
            }
        }
        guard !selectedByName.isEmpty else { return nil }
        let header = selectedByName.keys.sorted().compactMap { name in
            selectedByName[name].map { "\($0.name)=\($0.value)" }
        }.joined(separator: "; ")
        guard !header.isEmpty, header.utf8.count <= CookieReadRequest.maximumHeaderBytes else {
            return nil
        }
        return header
    }
}

/// Firefox's persisted `moz_cookies` store is a clean, unencrypted
/// SweetCookieKit adaptation. It remains private to the importer file so W1
/// does not create a seventh production path.
nonisolated struct FirefoxCookieReader: Sendable {
    private let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    func readCookies(request: CookieReadRequest) throws -> [BrowserCookieRecord] {
        let profileRoot = homeDirectory.appending(
            path: "Library/Application Support/Firefox/Profiles", directoryHint: .isDirectory)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: profileRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { throw BrowserCookieReadError.noStore }

        let profiles = entries.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { Self.profileSortKey($0) < Self.profileSortKey($1) }
            .prefix(32)

        let filter = CookieSQL.predicate(
            domainColumn: "host", nameColumn: "name", request: request)
        let sql = """
            SELECT host, name, path, value, expiry, isSecure, isHttpOnly
            FROM moz_cookies
            WHERE \(filter.clause)
            LIMIT \(CookieReadRequest.maximumRecords + 1)
            """
        var foundStore = false
        var readFailed = false
        for profile in profiles {
            guard !Task.isCancelled else { throw CancellationError() }
            let database = profile.appending(path: "cookies.sqlite")
            guard FileManager.default.fileExists(atPath: database.path) else { continue }
            foundStore = true
            do {
                let rows = try UsageSQLite.query(
                    databasePath: database.path,
                    sql: sql,
                    parameters: filter.parameters,
                    columns: ["host", "name", "path", "value", "expiry", "isSecure", "isHttpOnly"])
                guard rows.count <= CookieReadRequest.maximumRecords else {
                    throw BrowserCookieReadError.invalidStore
                }
                let records = rows.compactMap { Self.record(from: $0, request: request) }
                if !records.isEmpty { return records }
            } catch let error as BrowserCookieReadError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                readFailed = true
            }
        }
        if readFailed { throw BrowserCookieReadError.unreadableStore }
        if !foundStore { throw BrowserCookieReadError.noStore }
        return []
    }

    private static func profileSortKey(_ url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        let rank = name.contains("default-release") ? "0" : name.contains("default") ? "1" : "2"
        return "\(rank)-\(name)"
    }

    private static func record(
        from row: [String: String], request: CookieReadRequest
    ) -> BrowserCookieRecord? {
        guard let domain = row["host"], let name = row["name"], let value = row["value"],
            request.matches(domain: domain), request.matches(name: name)
        else { return nil }
        let expires = row["expiry"].flatMap(TimeInterval.init).map(
            Date.init(timeIntervalSince1970:))
        guard expires.map({ $0 >= request.referenceDate }) ?? true else { return nil }
        return BrowserCookieRecord(
            domain: domain,
            name: name,
            path: row["path"] ?? "/",
            value: value,
            expires: expires,
            isSecure: row["isSecure"] == "1",
            isHTTPOnly: row["isHttpOnly"] == "1")
    }
}
