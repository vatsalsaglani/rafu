import Foundation
import Testing

@testable import RafuCore

// The autorelease pools around the History loops must not change any result.
// These tests pin the pass-through of the helper, the line splitting, and the
// scanner and search outputs on the synthetic fixtures.

private struct PoolError: Error, Equatable {}

private func scannerOptions(_ homes: AgentHistoryFixtures.Homes) -> AgentHistoryScanner.Options {
    AgentHistoryScanner.Options(
        locations: AgentHistoryLocations(
            claudeProjectsDirectory: homes.locations.claudeProjects,
            codexHomeDirectory: homes.locations.codexHome))
}

@Test func autoreleasePoolHelperReturnsTheBodyValue() {
    #expect(withAutoreleasePool { 41 + 1 } == 42)
    let text = withAutoreleasePool { String(repeating: "ab", count: 3) }
    #expect(text == "ababab")
}

@Test func autoreleasePoolHelperRethrowsAndRunsTheBodyOnce() {
    var calls = 0
    #expect(throws: PoolError.self) {
        try withAutoreleasePool {
            calls += 1
            throw PoolError()
        }
    }
    #expect(calls == 1)
}

@Test func parsedObjectSurvivesThePoolInsideTheParser() throws {
    let data = Data(#"{"a":{"b":["x","y"]},"n":3}"#.utf8)
    let parsed = try #require(AgentHistoryJSON.object(data))
    let inner = try #require(AgentHistoryJSON.dictionary(parsed["a"]))
    #expect(AgentHistoryJSON.array(inner["b"])?.compactMap { $0 as? String } == ["x", "y"])
    #expect(AgentHistoryJSON.int(parsed["n"]) == 3)
}

@Test func jsonStringHelpersReturnEqualNativeValues() {
    let value = "  héllo wörld 日本語 🎉  "
    #expect(AgentHistoryJSON.native(value) == value)
    #expect(AgentHistoryJSON.native("") == "")
    #expect(AgentHistoryJSON.nonEmptyString(value) == "héllo wörld 日本語 🎉")
    #expect(AgentHistoryJSON.nonEmptyString("  \n ") == nil)
    let data = Data(#"{"t":"  héllo 🎉  "}"#.utf8)
    let parsed = AgentHistoryJSON.object(data)
    #expect(AgentHistoryJSON.nonEmptyString(parsed?["t"]) == "héllo 🎉")
}

@Test(arguments: [1, 2, 5, 17, 64, 1 << 20])
func forEachLineYieldsTheSameLinesForEveryChunkSize(chunkSize: Int) throws {
    let text = "alpha\n\nbeta 🎉\n{\"k\":1}\ngamma-without-newline"
    let url = try AgentHistoryFixtures.temporaryFile(text)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var seen: [String] = []
    let truncated = try AgentHistoryFileReader.forEachLine(
        url, maxBytes: 1 << 20, chunkSize: chunkSize
    ) { line in
        seen.append(String(decoding: line, as: UTF8.self))
        return true
    }
    #expect(truncated == false)
    #expect(seen == ["alpha", "beta 🎉", "{\"k\":1}", "gamma-without-newline"])
}

@Test func forEachLineStopsEarlyAndReportsTheByteLimit() throws {
    let text = "one\ntwo\nthree\nfour\n"
    let url = try AgentHistoryFixtures.temporaryFile(text)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    var first: [String] = []
    try AgentHistoryFileReader.forEachLine(url, maxBytes: 1 << 20, chunkSize: 3) { line in
        first.append(String(decoding: line, as: UTF8.self))
        return first.count < 2
    }
    #expect(first == ["one", "two"])

    var limited: [String] = []
    let truncated = try AgentHistoryFileReader.forEachLine(url, maxBytes: 10, chunkSize: 4) {
        line in
        limited.append(String(decoding: line, as: UTF8.self))
        return true
    }
    #expect(truncated)
    #expect(limited == ["one", "two"])
}

@Test func scannerSummaryMatchesTheParserForAFixtureFile() async throws {
    let homes = try AgentHistoryFixtures.makeHomes()
    defer { homes.remove() }
    let result = try await AgentHistoryScanner().scan(scannerOptions(homes))

    let file = homes.claudeFile.standardizedFileURL
    let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let size = try #require(values.fileSize)
    let modified = try #require(values.contentModificationDate)
    let parsed = try ClaudeCodeHistoryParser.summary(
        fileURL: file, size: Int64(size), modificationDate: modified)
    let direct = try #require(parsed)
    let scanned = try #require(result.index.sessions.first { $0.key == direct.key })
    #expect(scanned == direct)
    #expect(scanned.title == "Add a login form")
    #expect(scanned.projectPath == "/work/alpha")
    #expect(scanned.gitBranch == "feature/login")
}

@Test func messageSearchResultsAreStableAcrossRepeatedRuns() async throws {
    let homes = try AgentHistoryFixtures.makeHomes()
    defer { homes.remove() }
    let index = try await AgentHistoryScanner().scan(scannerOptions(homes)).index
    for _ in 0..<3 {
        let prompts = try await AgentHistoryMessageSearch.sessions(
            matching: "login form", in: index.sessions)
        #expect(prompts.map(\.sessionID) == [AgentHistoryFixtures.claudeSessionID])
        let codex = try await AgentHistoryMessageSearch.sessions(
            matching: "now passes", in: index.sessions)
        #expect(codex.map(\.sessionID) == [AgentHistoryFixtures.codexSessionID])
        let none = try await AgentHistoryMessageSearch.sessions(
            matching: "no such words anywhere", in: index.sessions)
        #expect(none.isEmpty)
    }
}

// MARK: Native strings
//
// A string read out of `JSONSerialization` output can wrap its `NSString`.
// `String.isContiguousUTF8` is false for such a string, so these tests fail
// if a `makeContiguousUTF8()` copy is removed from a kept value.

/// Longer than 15 UTF-8 bytes (no inline small string) and non-ASCII.
private let nativeFixtureText = "Größe prüfen 日本語 und 🎉 weiter, mit einem langen Satz"

/// `text` as a JSON string literal, escaped by `JSONSerialization`.
private func jsonLiteral(_ text: String) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: [text])
    return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
}

@Test func nonEmptyStringOutputIsContiguousUTF8() throws {
    // No padding: `trimmingCharacters` copies a padded string, which would
    // hide a missing `native` copy.
    let literal = try jsonLiteral(nativeFixtureText)
    let data = Data(#"{"t":\#(literal)}"#.utf8)
    let parsed = try #require(AgentHistoryJSON.object(data))
    let value = try #require(AgentHistoryJSON.nonEmptyString(parsed["t"]))
    #expect(value == nativeFixtureText)
    #expect(value.utf8.count > 15)
    #expect(value.isContiguousUTF8)
    #expect(AgentHistoryJSON.native(value).isContiguousUTF8)
}

@Test func transcriptItemTextAndDetailAreContiguousUTF8() throws {
    let message = try jsonLiteral(nativeFixtureText)
    let output = try jsonLiteral("Große Ausgabe der Prüfung 日本語 mit Zeilen\nzweite Zeile 🎉")
    let common = #""timestamp":"2026-01-02T10:00:05Z","sessionId":"s","cwd":"/work/alpha""#
    let lines =
        [
            #"{"type":"user","message":{"role":"user","content":\#(message)},\#(common)}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Edit","input":{"file_path":"/work/alpha/Größe日本語.swift","new_string":\#(message)}}]},\#(common)}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":\#(output),"is_error":false}]},\#(common)}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":\#(message)}]},\#(common)}"#,
        ].joined(separator: "\n") + "\n"
    let url = try AgentHistoryFixtures.temporaryFile(lines)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let value = try AgentTranscriptLoader.load(
        fileURL: url, key: AgentHistorySessionKey(provider: .claudeCode, sessionID: "s"),
        limits: .standard)

    #expect(value.items.count == 4)
    #expect(value.items.filter { $0.detail != nil }.count >= 2)
    #expect(value.items.contains { $0.text.utf8.count > 15 })
    for item in value.items {
        #expect(item.text.isContiguousUTF8, "item \(item.id) text is not native")
        if let detail = item.detail {
            #expect(detail.isContiguousUTF8, "item \(item.id) detail is not native")
        }
    }
}

@Test func codexSessionIndexTitlesAreContiguousUTF8() throws {
    let name = try jsonLiteral("Größe prüfen 日本語 und 🎉 weiter, mit einem langen Titel")
    let row = #"{"id":"22222222-2222-4222-8222-222222222222","thread_name":\#(name)}"# + "\n"
    let url = try AgentHistoryFixtures.temporaryFile(row, name: "session_index.jsonl")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let titles = try CodexSessionIndex.load(index: url)
    let title = try #require(titles["22222222-2222-4222-8222-222222222222"])
    #expect(title == "Größe prüfen 日本語 und 🎉 weiter, mit einem langen Titel")
    #expect(title.utf8.count > 15)
    #expect(title.isContiguousUTF8)
}
