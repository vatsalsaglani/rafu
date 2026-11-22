import Foundation
import Testing

@Suite("Meetings speech worker source scan")
struct MeetingWorkerSourceScanTests {
    private static func repositoryRoot(file: StaticString = #filePath) -> URL {
        // Tests/RafuCoreTests/Meetings/Worker/<file>
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func swiftSources(in relative: String) throws -> [(name: String, text: String)] {
        let folder = repositoryRoot().appendingPathComponent(relative, isDirectory: true)
        guard
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        var result: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return result
    }

    @Test("The helper has no network symbol and no download call")
    func helperHasNoNetwork() throws {
        let sources = try Self.swiftSources(in: "Sources/RafuMeetingsWorker")
        #expect(sources.count >= 4)
        let forbidden = [
            "URLSession", "URLRequest", "NWConnection", "loadFromHuggingFace", "downloadModels",
            "HubApi", "download: true", ".download(", "loadModels()", "loadModels(to:",
        ]
        for (name, text) in sources {
            for symbol in forbidden {
                #expect(!text.contains(symbol), "\(name) contains \(symbol)")
            }
        }
        // Each library that could download is told not to.
        let all = sources.map(\.text).joined()
        #expect(all.contains("download: false"))
        #expect(all.contains("loadModels(from:"))
        #expect(all.contains("Nemotron3Models.load("))
    }

    @Test("The helper writes no file: results go to standard output only")
    func helperWritesNoFile() throws {
        let forbidden = [
            ".write(to:", "createFile(", "FileHandle(forWritingAtPath", "FileHandle(forWritingTo",
            "fopen(", "AVAudioFile(forWriting",
        ]
        for (name, text) in try Self.swiftSources(in: "Sources/RafuMeetingsWorker") {
            for symbol in forbidden {
                #expect(!text.contains(symbol), "\(name) contains \(symbol)")
            }
        }
    }

    @Test("No target but the helper imports a speech package")
    func onlyTheHelperImportsSpeechPackages() throws {
        for folder in ["Sources/RafuApp", "Sources/RafuCore", "Sources/RafuCLI"] {
            for (name, text) in try Self.swiftSources(in: folder) {
                for module in ["FluidAudio", "WhisperKit", "SpeakerKit"] {
                    #expect(!text.contains("import \(module)"), "\(name) imports \(module)")
                }
            }
        }
    }
}
