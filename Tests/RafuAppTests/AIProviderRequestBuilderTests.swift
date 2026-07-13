import Foundation
import Testing

@testable import RafuApp

@Test("OpenAI Responses request uses bearer auth and disables storage")
func openAIResponsesRequestShape() throws {
    let configuration = AIProviderConfiguration(
        name: "OpenAI",
        kind: .openAI,
        baseURL: URL(string: "https://api.openai.com/v1")!,
        model: "gpt-5.1"
    )
    let request = try AIProviderRequestBuilder().makeStreamingRequest(
        configuration: configuration,
        apiKey: "secret-test-key",
        instructions: "System",
        prompt: "User"
    )
    let body = try requestJSONObject(request)

    #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-test-key")
    #expect(body["model"] as? String == "gpt-5.1")
    #expect(body["input"] as? String == "User")
    #expect(body["stream"] as? Bool == true)
    #expect(body["store"] as? Bool == false)
}

@Test("Anthropic Messages request uses versioned headers and messages body")
func anthropicMessagesRequestShape() throws {
    let configuration = AIProviderConfiguration(
        name: "Anthropic",
        kind: .anthropic,
        model: "claude-opus-4-20250514"
    )
    let request = try AIProviderRequestBuilder().makeStreamingRequest(
        configuration: configuration,
        apiKey: "anthropic-test-key",
        instructions: "System",
        prompt: "User"
    )
    let body = try requestJSONObject(request)

    #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "anthropic-test-key")
    #expect(
        request.value(forHTTPHeaderField: "anthropic-version")
            == AIProviderRequestBuilder.anthropicVersion
    )
    #expect(body["system"] as? String == "System")
    #expect(body["stream"] as? Bool == true)
}

@Test("Google request uses SSE endpoint and API key header")
func googleRequestShape() throws {
    let configuration = AIProviderConfiguration(
        name: "Google",
        kind: .google,
        model: "gemini-3.5-flash"
    )
    let request = try AIProviderRequestBuilder().makeStreamingRequest(
        configuration: configuration,
        apiKey: "google-test-key",
        instructions: "System",
        prompt: "User"
    )

    #expect(
        request.url?.absoluteString
            == "https://generativelanguage.googleapis.com/v1beta/models/"
            + "gemini-3.5-flash:streamGenerateContent?alt=sse"
    )
    #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "google-test-key")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test("Custom Chat Completions request uses the compatible token field")
func customChatCompletionsRequestShape() throws {
    let configuration = AIProviderConfiguration(
        name: "Custom",
        kind: .openAICompatible,
        baseURL: URL(string: "https://models.example/v1")!,
        model: "custom-model",
        openAITransport: .chatCompletions
    )
    let request = try AIProviderRequestBuilder().makeStreamingRequest(
        configuration: configuration,
        apiKey: "custom-test-key",
        instructions: "System",
        prompt: "User"
    )
    let body = try requestJSONObject(request)

    #expect(request.url?.absoluteString == "https://models.example/v1/chat/completions")
    #expect(body["max_tokens"] as? Int == 256)
    #expect(body["max_completion_tokens"] == nil)
}

private func requestJSONObject(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}
