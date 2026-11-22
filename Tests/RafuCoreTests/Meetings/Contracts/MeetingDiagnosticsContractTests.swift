import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting contracts: diagnostics and source policy")
struct MeetingDiagnosticsContractTests {
    @Test("A diagnostic string is cut to 128 bytes and loses control characters")
    func diagnosticStringCutsAndCleans() {
        #expect(MeetingDiagnosticString("AirPods\nPro\t2\u{0}").value == "AirPodsPro2")
        #expect(MeetingDiagnosticString("a\u{2028}b\u{202E}c\u{7F}d\u{85}e").value == "abcde")
        let long = String(repeating: "x", count: 300)
        #expect(MeetingDiagnosticString(long).value.utf8.count == 128)
        // A 3-byte character is never split at the limit.
        let wide = String(repeating: "é", count: 63) + "€€"
        let cut = MeetingDiagnosticString(wide).value
        #expect(cut.utf8.count <= 128)
        #expect(cut.hasPrefix(String(repeating: "é", count: 63)))
        #expect(cut.utf8.count == 126)
        // Decoding cleans too.
        let decoded = try? JSONDecoder().decode(
            MeetingDiagnosticString.self, from: Data(#""bad\u0007name""#.utf8))
        #expect(decoded?.value == "badname")
    }

    @Test("The no-op recorder takes each event")
    func noopRecorder() {
        let recorder: any MeetingDiagnosticsRecording = NoopMeetingDiagnostics()
        recorder.record(.recordingPaused, meeting: MeetingID())
        recorder.record(.exportDone(kind: .diagnostics), meeting: nil)
    }

    @Test("Contracts hold no @unchecked Sendable, no UI import and no workspace field")
    func contractsSourcePolicy() throws {
        let files = try Self.contractSources()
        #expect(files.count >= 10)
        for (name, source) in files {
            #expect(!source.contains("@unchecked Sendable"), "\(name)")
            #expect(!source.contains("import SwiftUI"), "\(name)")
            #expect(!source.contains("import AppKit"), "\(name)")
            for line in source.split(separator: "\n") where !Self.isComment(line) {
                let lowered = line.lowercased()
                let declaresField =
                    lowered.contains("var ") || lowered.contains("let ")
                    || lowered.contains("case ")
                #expect(!(declaresField && lowered.contains("workspace")), "\(name): \(line)")
            }
        }
    }

    @Test("A diagnostic event holds no String outside the wrapper")
    func diagnosticEventsHaveNoFreeText() throws {
        let files = try Self.contractSources()
        let source = try #require(files.first { $0.0 == "MeetingDiagnostics.swift" }?.1)
        for line in source.split(separator: "\n") where !Self.isComment(line) {
            // Remove the wrapper's name, then look for a bare String type.
            let stripped = line.replacingOccurrences(of: "MeetingDiagnosticString", with: "")
            #expect(!stripped.contains("String"), "\(line)")
            #expect(!stripped.contains("Substring"), "\(line)")
            #expect(!stripped.contains("Data"), "\(line)")
        }
    }

    private static func isComment(_ line: Substring) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    private static func contractSources(file: StaticString = #filePath) throws -> [(String, String)]
    {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/",
            !FileManager.default.fileExists(atPath: directory.appending(path: "Package.swift").path)
        {
            directory = directory.deletingLastPathComponent()
        }
        let folder = directory.appending(path: "Sources/RafuCore/Meetings/Contracts")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        return try names.map { name in
            (name, try String(contentsOf: folder.appending(path: name), encoding: .utf8))
        }
    }
}
