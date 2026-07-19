import Foundation
import Testing

@testable import RafuApp

/// Regression for "The provider returned an unreadable response": a single
/// empty or non-JSON SSE data line (keep-alives, bare "ping"/"OK" lines)
/// must be tolerated as `.ignored`, not fail the whole stream — the rest of
/// the reply is usually fine. Provider-reported errors still throw.
@Suite("AI provider stream decoder tolerance")
struct AIProviderStreamDecoderTests {
    private let decoder = AIProviderStreamDecoder()

    private var anthropicConfiguration: AIProviderConfiguration {
        AIProviderConfiguration(
            name: "Test",
            kind: .anthropic,
            baseURL: URL(string: "https://api.anthropic.com/v1")!,
            model: "claude-sonnet-5"
        )
    }

    @Test("An empty data line is ignored, not an error")
    func emptyDataIgnored() throws {
        let event = ServerSentEvent(event: "message", data: "", id: nil)
        let decoded = try decoder.decode(event, configuration: anthropicConfiguration)
        #expect(decoded == .ignored)
    }

    @Test("A non-JSON keep-alive data line is ignored, not an error")
    func nonJSONDataIgnored() throws {
        for junk in ["ping", "OK", ": keep-alive", "not { json"] {
            let event = ServerSentEvent(event: "message", data: junk, id: nil)
            let decoded = try decoder.decode(event, configuration: anthropicConfiguration)
            #expect(decoded == .ignored, "expected \(junk) to be ignored")
        }
    }

    @Test("Real deltas still decode after junk lines")
    func realDeltaStillDecodes() throws {
        let delta = """
            {"type":"content_block_delta","delta":{"type":"text_delta","text":"node_modules/"}}
            """
        let event = ServerSentEvent(event: "message", data: delta, id: nil)
        let decoded = try decoder.decode(event, configuration: anthropicConfiguration)
        #expect(decoded == .text("node_modules/"))
    }

    @Test("Provider-reported stream errors still throw")
    func providerErrorsStillThrow() {
        let error = """
            {"type":"error","error":{"message":"overloaded"}}
            """
        let event = ServerSentEvent(event: "message", data: error, id: nil)
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(event, configuration: anthropicConfiguration)
        }
    }

    @Test("[DONE] still terminates the stream")
    func doneStillTerminates() throws {
        let event = ServerSentEvent(event: "message", data: "[DONE]", id: nil)
        let decoded = try decoder.decode(event, configuration: anthropicConfiguration)
        #expect(decoded == .done)
    }
}
