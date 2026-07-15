import CryptoKit
import Foundation
import Testing

@testable import RafuApp

@Suite("Checksum verification")
struct ChecksumVerificationTests {
    @Test("A nil expected checksum reports notPublished without reading the file's contents")
    func nilExpectedChecksumReportsNotPublished() throws {
        let fileURL = try writeTemporaryFile(contents: Data("irrelevant".utf8))
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let status = try ServerInstaller.verifyChecksum(fileURL: fileURL, expected: nil)
        #expect(status == .notPublished)
    }

    @Test("A matching lowercase-hex SHA-256 checksum reports verified")
    func matchingChecksumReportsVerified() throws {
        let contents = Data("rafu-language-server-fixture".utf8)
        let fileURL = try writeTemporaryFile(contents: contents)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let digest = SHA256.hash(data: contents)
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        let status = try ServerInstaller.verifyChecksum(fileURL: fileURL, expected: hex)
        #expect(status == .verified)
    }

    @Test("An uppercase-hex expected checksum still matches (case-insensitive comparison)")
    func uppercaseExpectedChecksumStillMatches() throws {
        let contents = Data("rafu-language-server-fixture".utf8)
        let fileURL = try writeTemporaryFile(contents: contents)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let digest = SHA256.hash(data: contents)
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        let status = try ServerInstaller.verifyChecksum(
            fileURL: fileURL, expected: hex.uppercased())
        #expect(status == .verified)
    }

    @Test("A mismatched checksum throws checksumMismatch")
    func mismatchedChecksumThrows() throws {
        let fileURL = try writeTemporaryFile(contents: Data("actual contents".utf8))
        defer { try? FileManager.default.removeItem(at: fileURL) }

        #expect(throws: ServerInstallError.checksumMismatch) {
            try ServerInstaller.verifyChecksum(
                fileURL: fileURL,
                expected: String(repeating: "0", count: 64))
        }
    }

    private func writeTemporaryFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "rafu-checksum-fixture-\(UUID().uuidString)")
        try contents.write(to: url)
        return url
    }
}
