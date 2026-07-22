// Adapted from CodexBar/SweetCookieKit's ChromeCookieImporter, MIT License.
// Differences required by Rafu: bound UsageSQLite queries, no temporary copy
// of the credential database, v10 + v11 support, and injected derived keys
// for tests so CI never reads a real browser or Keychain.

import CommonCrypto
import CryptoKit
import Foundation
import Security

nonisolated struct ChromiumCookieReader: Sendable {
    typealias KeyProvider = @Sendable (Browser) throws -> Data

    private struct ProfileStores: Sendable {
        let profileName: String
        let databases: [URL]
    }

    private struct RecordKey: Hashable, Sendable {
        let domain: String
        let path: String
        let name: String
    }

    private let homeDirectory: URL
    private let keyProvider: KeyProvider

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        keyProvider: @escaping KeyProvider = ChromiumCookieReader.safeStorageKey
    ) {
        self.homeDirectory = homeDirectory
        self.keyProvider = keyProvider
    }

    func readCookies(
        for browser: Browser, request: CookieReadRequest
    ) throws -> [BrowserCookieRecord] {
        guard browser.chromiumProfileRelativePath != nil else {
            throw BrowserCookieReadError.noStore
        }
        let profiles = profileStores(for: browser)
        guard !profiles.isEmpty else { throw BrowserCookieReadError.noStore }

        var derivedKey: Data?
        var readFailed = false
        for profile in profiles {
            var recordsByKey: [RecordKey: BrowserCookieRecord] = [:]
            for database in profile.databases {
                do {
                    let records = try readDatabase(
                        database,
                        browser: browser,
                        request: request,
                        derivedKey: &derivedKey)
                    for record in records {
                        let key = RecordKey(
                            domain: record.domain.lowercased(), path: record.path, name: record.name
                        )
                        if let existing = recordsByKey[key] {
                            if (record.expires ?? .distantFuture)
                                > (existing.expires ?? .distantFuture)
                            {
                                recordsByKey[key] = record
                            }
                        } else {
                            // Network/Cookies is ordered before legacy Cookies,
                            // so equal records keep the modern store's value.
                            recordsByKey[key] = record
                        }
                    }
                } catch let error as BrowserCookieReadError {
                    switch error {
                    case .keychainDenied, .invalidStore:
                        throw error
                    case .noStore, .needsFullDiskAccess, .unreadableStore:
                        readFailed = true
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    readFailed = true
                }
            }
            guard recordsByKey.count <= CookieReadRequest.maximumRecords else {
                throw BrowserCookieReadError.invalidStore
            }
            if !recordsByKey.isEmpty {
                return recordsByKey.values.sorted { lhs, rhs in
                    if lhs.name != rhs.name { return lhs.name < rhs.name }
                    if lhs.path.count != rhs.path.count { return lhs.path.count > rhs.path.count }
                    return lhs.domain < rhs.domain
                }
            }
        }
        if readFailed { throw BrowserCookieReadError.unreadableStore }
        return []
    }

    private func profileStores(for browser: Browser) -> [ProfileStores] {
        guard let relativePath = browser.chromiumProfileRelativePath else { return [] }
        let root =
            homeDirectory
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: relativePath, directoryHint: .isDirectory)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }

        let directories = entries.filter { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return false
            }
            let name = url.lastPathComponent
            return name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-")
        }.sorted { Self.profileSortKey($0) < Self.profileSortKey($1) }
            .prefix(32)

        return directories.compactMap { directory in
            let candidates = [
                directory.appending(path: "Network/Cookies"),
                directory.appending(path: "Cookies"),
            ].filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !candidates.isEmpty else { return nil }
            return ProfileStores(profileName: directory.lastPathComponent, databases: candidates)
        }
    }

    private func readDatabase(
        _ database: URL,
        browser: Browser,
        request: CookieReadRequest,
        derivedKey: inout Data?
    ) throws -> [BrowserCookieRecord] {
        let filter = CookieSQL.predicate(
            domainColumn: "host_key", nameColumn: "name", request: request)
        let sql = """
            SELECT host_key, name, path, expires_utc, is_secure, is_httponly,
                   value, hex(encrypted_value)
            FROM cookies
            WHERE \(filter.clause)
            LIMIT \(CookieReadRequest.maximumRecords + 1)
            """
        let rows: [[String: String]]
        do {
            rows = try UsageSQLite.query(
                databasePath: database.path,
                sql: sql,
                parameters: filter.parameters,
                columns: [
                    "host_key", "name", "path", "expires_utc", "is_secure", "is_httponly",
                    "value", "encrypted_value_hex",
                ])
        } catch {
            throw BrowserCookieReadError.unreadableStore
        }
        guard rows.count <= CookieReadRequest.maximumRecords else {
            throw BrowserCookieReadError.invalidStore
        }

        var records: [BrowserCookieRecord] = []
        records.reserveCapacity(rows.count)
        for row in rows {
            guard !Task.isCancelled else { throw CancellationError() }
            guard let domain = row["host_key"], let name = row["name"],
                request.matches(domain: domain), request.matches(name: name)
            else { continue }

            let value: String
            if let plaintext = row["value"], !plaintext.isEmpty {
                value = plaintext
            } else {
                guard let hex = row["encrypted_value_hex"], let encrypted = Self.data(fromHex: hex),
                    !encrypted.isEmpty
                else { continue }
                let key: Data
                if let derivedKey {
                    key = derivedKey
                } else {
                    do {
                        key = try keyProvider(browser)
                    } catch {
                        throw BrowserCookieReadError.keychainDenied
                    }
                    derivedKey = key
                }
                guard
                    let decrypted = Self.decryptChromiumValue(
                        encrypted, hostKey: domain, key: key)
                else { throw BrowserCookieReadError.invalidStore }
                value = decrypted
            }

            let expires = row["expires_utc"].flatMap(Int64.init).flatMap(Self.expiryDate)
            guard expires.map({ $0 >= request.referenceDate }) ?? true else { continue }
            records.append(
                BrowserCookieRecord(
                    domain: domain,
                    name: name,
                    path: row["path"] ?? "/",
                    value: value,
                    expires: expires,
                    isSecure: row["is_secure"] == "1",
                    isHTTPOnly: row["is_httponly"] == "1"))
        }
        return records
    }

    static func deriveKey(from password: String) throws -> Data {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyLength = key.count
        let result = key.withUnsafeMutableBytes { keyBytes in
            password.utf8CString.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordBytes.count - 1,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength)
                }
            }
        }
        guard result == kCCSuccess else { throw BrowserCookieReadError.keychainDenied }
        return key
    }

    static func decryptChromiumValue(
        _ encryptedValue: Data,
        hostKey: String,
        key: Data
    ) -> String? {
        guard encryptedValue.count > 3, key.count == kCCKeySizeAES128 else { return nil }
        let prefix = String(data: encryptedValue.prefix(3), encoding: .ascii)
        guard prefix == "v10" || prefix == "v11" else { return nil }
        let payload = encryptedValue.dropFirst(3)
        let initializationVector = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        var outputLength: size_t = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    initializationVector.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            payload.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.count = outputLength

        let hostDigestByteCount = 32
        if output.count > hostDigestByteCount {
            let digest = Data(SHA256.hash(data: Data(hostKey.utf8)))
            if output.prefix(hostDigestByteCount) == digest {
                output.removeFirst(hostDigestByteCount)
            }
        }
        return String(data: output, encoding: .utf8)
    }

    private static func safeStorageKey(for browser: Browser) throws -> Data {
        guard let label = browser.safeStorageLabel else {
            throw BrowserCookieReadError.keychainDenied
        }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: label.service,
            kSecAttrAccount: label.account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let password = String(data: data, encoding: .utf8),
            !password.isEmpty
        else { throw BrowserCookieReadError.keychainDenied }
        return try deriveKey(from: password)
    }

    private static func profileSortKey(_ url: URL) -> String {
        let name = url.lastPathComponent
        let rank = name == "Default" ? "0" : name.hasPrefix("Profile ") ? "1" : "2"
        return "\(rank)-\(name.lowercased())"
    }

    private static func expiryDate(_ microsecondsSince1601: Int64) -> Date? {
        guard microsecondsSince1601 > 0 else { return nil }
        let seconds = Double(microsecondsSince1601) / 1_000_000 - 11_644_473_600
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func data(fromHex hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2),
            hex.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
            })
        else { return nil }
        var data = Data()
        data.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
