import Foundation
import Testing

@testable import RafuApp

/// conductor/C1: PTY output evidence capture
/// (`Sources/RafuApp/Conductor/Run/ConductorRunOutputCapture.swift`).
///
/// No real PTY here: `forkpty` deadlocks a heavily threaded test process
/// under a parallel `swift test` run (verified precedent —
/// `ConductorTerminalSpecTests.swift`'s `runResolvedLaunch(_:)` comment
/// documents the same failure for `SwiftTerm.LocalProcess`). Driving
/// `ConductorRunOutputCapture.record(_:)` directly exercises exactly the
/// same main-actor accounting `RafuTerminalView.dataReceived(slice:)` calls
/// it with, without ever mounting an AppKit view or spawning a process.

private func makeCaptureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(
            path: "rafu-run-output-capture-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor
@Test("Ordering: many small chunks land in the file in exactly the order recorded")
func captureWritesChunksInOrder() async throws {
    let root = try makeCaptureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outputURL = root.appending(path: "output.log", directoryHint: .notDirectory)
    let capture = ConductorRunOutputCapture(outputLogURL: outputURL)

    var expected = Data()
    for index in 0..<500 {
        let chunk = Data("chunk-\(index)\n".utf8)
        expected.append(chunk)
        capture.record(ArraySlice(chunk))
    }
    capture.finish()
    await capture.waitUntilFinished()

    let written = try Data(contentsOf: outputURL)
    #expect(written == expected)
}

@MainActor
@Test(
    "Bounded cap: output stops growing at 8 MiB and ends with exactly one truncation marker")
func captureTruncatesAtCap() async throws {
    let root = try makeCaptureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outputURL = root.appending(path: "output.log", directoryHint: .notDirectory)
    let capture = ConductorRunOutputCapture(outputLogURL: outputURL)

    let markerData = Data("\n[rafu: run output truncated at 8 MiB]\n".utf8)
    // Filled with a byte the marker text never contains, so any accidental
    // second occurrence of the marker would be unambiguous.
    let chunk = Data(repeating: 0x41, count: 64 * 1_024)
    // 64 KiB * 200 = 12.5 MiB — comfortably beyond the 8 MiB cap, and fed as
    // many separate `record(_:)` calls the way real pty reads would arrive.
    for _ in 0..<200 {
        capture.record(ArraySlice(chunk))
    }
    capture.finish()
    await capture.waitUntilFinished()

    let written = try Data(contentsOf: outputURL)
    #expect(written.count <= ConductorRunOutputCapture.byteCap + markerData.count)
    #expect(written.suffix(markerData.count) == markerData)
    #expect(written.dropLast(markerData.count).firstRange(of: markerData) == nil)
}

@MainActor
@Test("Run-dir-only: capture writes solely to the one URL it was constructed with")
func captureWritesOnlyToItsOwnURL() async throws {
    let root = try makeCaptureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outputURL = root.appending(path: "output.log", directoryHint: .notDirectory)
    let capture = ConductorRunOutputCapture(outputLogURL: outputURL)

    capture.record(ArraySlice(Data("hello\n".utf8)))
    capture.finish()
    await capture.waitUntilFinished()

    let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(entries == ["output.log"])
}

@Test(
    "A spec built without outputLogURL carries nil — the exact guard WorkspaceTerminalController.makeOrReuseView(theme:) uses to skip capture entirely on the login-shell and capture-less Conductor paths"
)
func specWithoutOutputLogURLCarriesNil() {
    let spec = TerminalProcessSpec(
        executableURL: URL(fileURLWithPath: "/bin/echo"),
        arguments: ["hi"],
        currentDirectoryPath: "/tmp",
        environment: [:],
        roleBadge: "advisor")
    #expect(spec.outputLogURL == nil)
}
