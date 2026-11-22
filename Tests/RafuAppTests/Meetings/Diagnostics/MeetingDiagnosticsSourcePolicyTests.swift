import Foundation
import Testing

@Suite("Meeting diagnostics: source policy")
struct MeetingDiagnosticsSourcePolicyTests {
    /// The one file under `Meetings/` that may log.
    static let loggerFile = "Sources/RafuApp/Meetings/Diagnostics/MeetingDiagnosticsLogger.swift"

    /// A call that writes to a console or a system log.
    private static let forbiddenCalls: [(name: String, pattern: String)] = [
        ("print", #"(^|[^A-Za-z0-9_.])print\("#),
        ("debugPrint", #"(^|[^A-Za-z0-9_.])debugPrint\("#),
        ("NSLog", #"(^|[^A-Za-z0-9_.])NSLog\("#),
        ("Logger", #"(^|[^A-Za-z0-9_.])Logger\("#),
        ("os_log", #"(^|[^A-Za-z0-9_.])os_log\("#),
    ]

    @Test("No print, NSLog or Logger call under Sources/*/Meetings/ outside the logger file")
    func noLoggingOutsideTheLoggerFile() throws {
        let files = try Self.meetingsSources()
        #expect(files.count >= 10, "the scan found \(files.count) files")
        var offenders: [String] = []
        for (path, source) in files where path != Self.loggerFile {
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
            {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for call in Self.forbiddenCalls
                where line.range(of: call.pattern, options: .regularExpression) != nil {
                    offenders.append("\(path):\(index + 1) \(call.name)")
                }
            }
        }
        #expect(offenders.isEmpty, "Files that log outside the logger file: \(offenders)")
    }

    @Test("The logger file is the one place that creates the meetings Logger")
    func loggerFileUsesTheSubsystemAndCategory() throws {
        let source = try #require(
            try Self.meetingsSources().first { $0.0 == Self.loggerFile }?.1)
        #expect(source.contains("static let subsystem = \"dev.vatsalsaglani.rafu\""))
        #expect(source.contains("static let category = \"meetings\""))
        #expect(source.contains("privacy: .private"))
    }

    @Test("A MeetingDiagnosticEvent case has no String-typed value outside the wrapper")
    func eventCasesHaveNoFreeText() throws {
        let root = Self.repositoryRoot()
        let source = try String(
            contentsOf: root.appending(
                path: "Sources/RafuCore/Meetings/Contracts/MeetingDiagnostics.swift"),
            encoding: .utf8)
        let start = try #require(source.range(of: "public enum MeetingDiagnosticEvent"))
        let end = try #require(source.range(of: "public protocol MeetingDiagnosticsRecording"))
        let body = source[start.upperBound..<end.lowerBound]
        var checked = 0
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            let stripped = trimmed.replacingOccurrences(of: "MeetingDiagnosticString", with: "")
            for forbidden in ["String", "Substring", "Data", "URL"] {
                #expect(!stripped.contains(forbidden), "\(trimmed)")
            }
            if trimmed.hasPrefix("case ") { checked += 1 }
        }
        #expect(checked >= 34)
    }

    // MARK: Helpers

    static func repositoryRoot(file: StaticString = #filePath) -> URL {
        var root = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while root.path != "/",
            !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path)
        {
            root = root.deletingLastPathComponent()
        }
        return root
    }

    /// Each Swift file in `Sources/<target>/Meetings/`, with its repository path.
    static func meetingsSources() throws -> [(String, String)] {
        let sources = repositoryRoot().appending(path: "Sources")
        var result: [(String, String)] = []
        for target in try FileManager.default.contentsOfDirectory(atPath: sources.path) {
            let base = sources.appending(path: "\(target)/Meetings")
            guard let enumerator = FileManager.default.enumerator(atPath: base.path) else {
                continue
            }
            for case let relative as String in enumerator where relative.hasSuffix(".swift") {
                let source = try String(
                    contentsOf: base.appending(path: relative), encoding: .utf8)
                result.append(("Sources/\(target)/Meetings/\(relative)", source))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }
}
