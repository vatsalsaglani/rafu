import Foundation
import Synchronization
import Testing

@testable import RafuCore

/// A temporary folder that is removed when the test ends.
final class DiagnosticsTemporaryFolder: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "rafu-diagnostics-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func child(_ name: String) -> URL {
        url.appending(path: name)
    }
}

/// Reads and parses diagnostics files.
enum DiagnosticsFiles {
    static func lines(at url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    static func objects(at url: URL) throws -> [[String: Any]] {
        try lines(at: url).map { line in
            try #require(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    static func permissions(of url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        return (value as? NSNumber)?.intValue ?? -1
    }

    static func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// Every regular file below `root`, as a path relative to it.
    static func allFiles(below root: URL) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result.append(url)
            }
        }
        return result
    }

    /// Unzips with `/usr/bin/ditto -x -k` into a new folder.
    static func unzip(_ zip: URL, into destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }
}

/// A log sink that keeps what it gets, rendered as the mirror renders it.
final class CapturingLogSink: MeetingDiagnosticsLogSink {
    struct Captured: Sendable {
        var name: String
        var publicText: String
        var privateText: String
        var meeting: MeetingID?
    }

    private let storage = Mutex<[Captured]>([])

    func log(_ description: MeetingDiagnosticDescription, meeting: MeetingID?) {
        let text = MeetingDiagnosticLogText(description)
        storage.withLock {
            $0.append(
                Captured(
                    name: description.name, publicText: text.publicText,
                    privateText: text.privateText, meeting: meeting))
        }
    }

    var captured: [Captured] { storage.withLock { $0 } }
}

/// A clock that moves one second at each read.
final class SteppingClock: Sendable {
    private let reads = Mutex(0)
    let start: Date

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.start = start
    }

    func now() -> Date {
        let index = reads.withLock { value -> Int in
            defer { value += 1 }
            return value
        }
        return start.addingTimeInterval(Double(index))
    }
}

let diagnosticsTestHeader = MeetingDiagnosticsHeader(
    macOSVersion: "26.1.0", macOSBuild: "25B78", macModel: "Mac17,13", rafuVersion: "0.1.0-dev",
    rafuBuild: "1", rafuVariant: "lightning", timeZoneOffsetSeconds: 0)
