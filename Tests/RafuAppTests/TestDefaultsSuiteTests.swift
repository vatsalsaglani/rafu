import Foundation
import Testing

/// Test suites for `UserDefaults` must not leak plists into
/// `~/Library/Preferences` (docs/references/test-defaults-suites.md).
@Suite("Test UserDefaults suites")
struct TestDefaultsSuiteTests {
    @Test("A test suite lives in its own temporary directory and removal deletes it")
    func suiteLivesInTemporaryDirectory() throws {
        let name = TestDefaultsSuite.name("probe")
        let directory = try #require(TestDefaultsSuite.ownedDirectory(of: name))
        #expect(name.hasPrefix("/"))
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.set("value", forKey: "key")
        #expect(CFPreferencesAppSynchronize(name as CFString))
        #expect(UserDefaults(suiteName: name)?.string(forKey: "key") == "value")
        #expect(FileManager.default.fileExists(atPath: name + ".plist"))

        TestDefaultsSuite.remove(name)
        #expect(UserDefaults(suiteName: name)?.string(forKey: "key") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Removal never deletes a directory it did not make")
    func removalStaysInItsOwnDirectory() {
        #expect(TestDefaultsSuite.ownedDirectory(of: "dev.rafu.plain.\(UUID().uuidString)") == nil)
        #expect(TestDefaultsSuite.ownedDirectory(of: NSHomeDirectory() + "/Library/x") == nil)
        let temporary = FileManager.default.temporaryDirectory
        #expect(
            TestDefaultsSuite.ownedDirectory(
                of: temporary.appending(path: "other-\(UUID().uuidString)/label").path) == nil)
    }

    @Test("No test names a UserDefaults suite with a bare UUID string")
    func noBareUUIDSuiteNames() throws {
        let tests = try Self.testsDirectory()
        let bare = try NSRegularExpression(
            pattern:
                #"(?:suiteName|defaultsSuiteName): "[^"]*\\\(UUID|(?:let|var) \w*[Ss]uite\w* = "[^"]*\\\(UUID"#
        )
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            if bare.firstMatch(in: text, range: range) != nil {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "Use TestDefaultsSuite.name(_:) in \(offenders)")
    }

    private static func testsDirectory(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return directory.appending(path: "Tests", directoryHint: .isDirectory)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
