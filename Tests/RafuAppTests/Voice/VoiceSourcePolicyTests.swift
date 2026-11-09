import AppKit
import Foundation
import Testing

@testable import RafuApp

/// Source policy for Rafu Voice: no logging, no idle clocks, and the key
/// reaches exactly one place. A rendered-view test cannot see these; a scan
/// keeps them from eroding.
@Suite("Voice source policy")
struct VoiceSourcePolicyTests {
    private static let folders = ["Sources/RafuApp/Voice", "Sources/RafuCore/Voice"]

    /// The opt-in debug transcript (ADR 0035 amendment) is the one exception
    /// to "no logging": a local file written through `VoiceDebugTranscript`,
    /// not a logging API, and covered by `VoiceDebugTranscriptTests`.
    @Test("No logging, no TimelineView, no key-window grab in Voice")
    func noLogging() throws {
        let banned = [
            "print(", "NSLog(", "os_log", "Logger(", "debugPrint(", "TimelineView", "makeKey(",
        ]
        var offenders: [String] = []
        for (path, source) in try Self.sources() {
            for needle in banned where source.contains(needle) {
                offenders.append("\(path) — \(needle)")
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: ", ")))
    }

    @Test("Only the transport touches the Authorization header")
    func authorizationInOneFile() throws {
        let holders = try Self.sources().filter { $0.1.contains("Authorization") }.map(\.0)
        #expect(holders == ["Sources/RafuApp/Voice/VoiceLiveTransport.swift"])
    }

    @Test("Only the debug transcript names the Logs folder")
    func logsFolderInOneFile() throws {
        let holders = try Self.sources().filter { $0.1.contains("Logs") }.map(\.0)
        #expect(holders == ["Sources/RafuApp/Voice/VoiceDebugTranscript.swift"])
    }

    @Test("No UserDefaults write of anything named key, and no spike Keychain item")
    func noSecretInDefaults() throws {
        for (path, source) in try Self.sources() {
            for line in source.split(separator: "\n") where line.contains(".set(") {
                #expect(!line.lowercased().contains("apikey"), Comment(rawValue: path))
                #expect(!line.lowercased().contains("secret"), Comment(rawValue: path))
            }
            #expect(!source.contains("voice-spike"), Comment(rawValue: path))
        }
    }

    @Test("The menu chord is not the push-to-talk chord")
    func chords() {
        #expect(VoiceHotkey.isChord(keyCode: 49, modifiers: [.control, .option]))
        #expect(VoiceHotkey.isChord(keyCode: 49, modifiers: [.control, .option, .capsLock]))
        #expect(!VoiceHotkey.isChord(keyCode: 49, modifiers: [.control, .option, .shift]))
        #expect(!VoiceHotkey.isChord(keyCode: 49, modifiers: [.control]))
        #expect(!VoiceHotkey.isChord(keyCode: 50, modifiers: [.control, .option]))
    }

    @Test("The staged Info.plist asks for the microphone with the agreed sentence")
    func microphoneUsage() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot().appending(path: "script/build_and_run.sh"),
            encoding: .utf8)
        #expect(script.contains("<key>NSMicrophoneUsageDescription</key>"))
        #expect(script.contains("Rafu listens only while you hold ⌃⌥Space"))
    }

    // MARK: Helpers

    private static func sources() throws -> [(String, String)] {
        let root = try repositoryRoot()
        var result: [(String, String)] = []
        for folder in folders {
            let url = root.appending(path: folder, directoryHint: .isDirectory)
            let files = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "swift" }
            for file in files.sorted(by: { $0.path < $1.path }) {
                result.append(
                    (
                        "\(folder)/\(file.lastPathComponent)",
                        try String(contentsOf: file, encoding: .utf8)
                    ))
            }
        }
        #expect(result.count > 10)
        return result
    }

    private static func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
