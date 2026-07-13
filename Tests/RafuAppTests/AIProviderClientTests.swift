import Foundation
import Synchronization
import Testing

@testable import RafuApp

@Test("Connection test accepts only the exact streamed phrase through URLProtocol")
func aiConnectionTestUsesStreamingREST() async throws {
    let host = "provider-\(UUID().uuidString.lowercased()).example"
    let baseURL = try #require(URL(string: "https://\(host)/v1"))
    let endpoint = try #require(URL(string: "https://\(host)/v1/responses"))
    AIURLProtocolStub.register(
        endpoint,
        response: .init(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: Data(
                """
                event: response.output_text.delta
                data: {"type":"response.output_text.delta","delta":"Rafu "}

                event: response.output_text.delta
                data: {"type":"response.output_text.delta","delta":"live!"}

                event: response.completed
                data: {"type":"response.completed"}

                """.utf8
            )
        )
    )

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AIURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    let client = AIProviderClient(session: session)
    let provider = AIProviderConfiguration(
        name: "Mock",
        kind: .openAICompatible,
        baseURL: baseURL,
        model: "mock-model"
    )

    let result = try await client.testConnection(
        configuration: provider,
        apiKey: "mock-secret"
    )
    #expect(result.response == "Rafu live!")

    let received = try #require(AIURLProtocolStub.receivedRequest(for: endpoint))
    #expect(received.value(forHTTPHeaderField: "Authorization") == "Bearer mock-secret")
}

@Test("Connection test rejects responses that are not the exact phrase")
func aiConnectionTestRejectsExtraText() async throws {
    let host = "mismatch-\(UUID().uuidString.lowercased()).example"
    let baseURL = try #require(URL(string: "https://\(host)/v1"))
    let endpoint = try #require(URL(string: "https://\(host)/v1/responses"))
    AIURLProtocolStub.register(
        endpoint,
        response: .init(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: Data(
                """
                event: response.output_text.delta
                data: {"type":"response.output_text.delta","delta":"Rafu live!\\n"}

                event: response.completed
                data: {"type":"response.completed"}

                """.utf8
            )
        )
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AIURLProtocolStub.self]
    let client = AIProviderClient(session: URLSession(configuration: configuration))
    let provider = AIProviderConfiguration(
        name: "Mock",
        kind: .openAICompatible,
        baseURL: baseURL,
        model: "mock-model"
    )

    await #expect(throws: AIProviderError.connectionTestMismatch) {
        try await client.testConnection(configuration: provider, apiKey: "mock-secret")
    }
}

@Test("HTTP failures expose bounded status and request ID without response bodies")
func aiProviderHTTPFailureIsBounded() async throws {
    let host = "rejected-\(UUID().uuidString.lowercased()).example"
    let baseURL = try #require(URL(string: "https://\(host)/v1"))
    let endpoint = try #require(URL(string: "https://\(host)/v1/responses"))
    AIURLProtocolStub.register(
        endpoint,
        response: .init(
            statusCode: 401,
            headers: ["x-request-id": "request-test"],
            body: Data(#"{"error":{"message":"mock-secret should never escape"}}"#.utf8)
        )
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AIURLProtocolStub.self]
    let client = AIProviderClient(session: URLSession(configuration: configuration))
    let provider = AIProviderConfiguration(
        name: "Mock",
        kind: .openAICompatible,
        baseURL: baseURL,
        model: "mock-model"
    )

    await #expect(
        throws: AIProviderError.providerRejected(
            statusCode: 401,
            requestID: "request-test"
        )
    ) {
        try await client.testConnection(configuration: provider, apiKey: "mock-secret")
    }
}

private final class AIURLProtocolStub: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var statusCode: Int
        var headers: [String: String]
        var body: Data
    }

    private struct State: Sendable {
        var responses: [String: Response] = [:]
        var requests: [String: URLRequest] = [:]
    }

    private static let state = Mutex(State())

    static func register(_ url: URL, response: Response) {
        state.withLock { $0.responses[url.absoluteString] = response }
    }

    static func receivedRequest(for url: URL) -> URLRequest? {
        state.withLock { $0.requests[url.absoluteString] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = Self.state.withLock { state -> Response? in
            state.requests[url.absoluteString] = request
            return state.responses[url.absoluteString]
        }
        guard let response,
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
