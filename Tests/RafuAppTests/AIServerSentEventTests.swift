import Foundation
import Testing

@testable import RafuApp

@Test("SSE parser joins data lines and preserves the event name")
func serverSentEventParserJoinsLines() throws {
    var parser = ServerSentEventParser()
    #expect(try parser.consume(line: "event: custom") == nil)
    #expect(try parser.consume(line: "data: first") == nil)
    #expect(try parser.consume(line: "data: second") == nil)
    let event = try #require(try parser.consume(line: ""))

    #expect(event.event == "custom")
    #expect(event.data == "first\nsecond")
}

@Test("Provider stream decoder handles all supported text delta shapes")
func providerStreamDecoderShapes() throws {
    let decoder = AIProviderStreamDecoder()
    let openAI = AIProviderConfiguration(name: "OpenAI", kind: .openAI)
    let anthropic = AIProviderConfiguration(name: "Anthropic", kind: .anthropic)
    let google = AIProviderConfiguration(name: "Google", kind: .google)

    #expect(
        try decoder.decode(
            ServerSentEvent(
                event: "response.output_text.delta",
                data: #"{"type":"response.output_text.delta","delta":"Rafu"}"#,
                id: nil
            ),
            configuration: openAI
        ) == .text("Rafu")
    )
    #expect(
        try decoder.decode(
            ServerSentEvent(
                event: "content_block_delta",
                data:
                    #"{"type":"content_block_delta","delta":{"type":"text_delta","text":" live"}}"#,
                id: nil
            ),
            configuration: anthropic
        ) == .text(" live")
    )
    #expect(
        try decoder.decode(
            ServerSentEvent(
                event: "message",
                data: #"{"candidates":[{"content":{"parts":[{"text":"!"}]}}]}"#,
                id: nil
            ),
            configuration: google
        ) == .text("!")
    )
}
