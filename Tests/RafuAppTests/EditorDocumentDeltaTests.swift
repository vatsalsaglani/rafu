import Foundation
import Testing

@testable import RafuApp

@MainActor
@Test("recordEditDelta multicasts the mapped delta to every subscriber and bumps its version")
func editDocumentDeltaMulticastsToAllSubscribers() async throws {
    let document = EditorDocument(url: URL(fileURLWithPath: "/tmp/Scratch.swift"))

    // Both streams must be minted before the emission they're expected to
    // observe — an `AsyncStream` created after `recordEditDelta` would miss
    // it entirely.
    let firstStream = document.editDeltas()
    let secondStream = document.editDeltas()
    var firstIterator = firstStream.makeAsyncIterator()
    var secondIterator = secondStream.makeAsyncIterator()

    document.recordEditDelta(
        editedRange: NSRange(location: 5, length: 3), changeInLength: 2)

    let expectedFirstDelta = DocumentEditDelta(
        range: NSRange(location: 5, length: 1), replacementLength: 3, version: 1)
    let firstReceived = try #require(await firstIterator.next())
    let secondReceived = try #require(await secondIterator.next())
    #expect(firstReceived == expectedFirstDelta)
    #expect(secondReceived == expectedFirstDelta)

    document.recordEditDelta(
        editedRange: NSRange(location: 0, length: 0), changeInLength: 0)

    let secondEmission = try #require(await firstIterator.next())
    #expect(secondEmission.version == 2)
}
