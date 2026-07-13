import Foundation

nonisolated struct AIConnectionTestResult: Equatable, Sendable {
    var response: String
}

nonisolated struct AIProviderClient: Sendable {
    static let connectionTestPhrase = "Rafu live!"
    static let maximumOutputBytes = 64 * 1_024
    static let maximumWireBytes = 2 * 1_024 * 1_024

    private let session: URLSession
    private let requestBuilder: AIProviderRequestBuilder
    private let promptBuilder: AICommitPromptBuilder

    init(
        session: URLSession = .shared,
        requestBuilder: AIProviderRequestBuilder = AIProviderRequestBuilder(),
        promptBuilder: AICommitPromptBuilder = AICommitPromptBuilder()
    ) {
        self.session = session
        self.requestBuilder = requestBuilder
        self.promptBuilder = promptBuilder
    }

    func testConnection(
        configuration: AIProviderConfiguration,
        apiKey: String
    ) async throws -> AIConnectionTestResult {
        let stream = try makeTextStream(
            configuration: configuration,
            apiKey: apiKey,
            instructions: "Reply with exactly the requested text and nothing else.",
            prompt: "Reply with exactly: \(Self.connectionTestPhrase)"
        )
        var output = ""
        for try await delta in stream {
            output += delta
            guard output.utf8.count <= Self.maximumOutputBytes else {
                throw AIProviderError.responseTooLarge(maximumBytes: Self.maximumOutputBytes)
            }
        }
        guard output == Self.connectionTestPhrase else {
            throw AIProviderError.connectionTestMismatch
        }
        return AIConnectionTestResult(response: output)
    }

    func generateCommitMessage(
        configuration: AIProviderConfiguration,
        apiKey: String,
        input: AICommitPromptInput
    ) throws -> AsyncThrowingStream<String, Error> {
        let prompt = try promptBuilder.makePrompt(input: input)
        let instructions = promptBuilder.instructions(for: input)
        return try makeTextStream(
            configuration: configuration,
            apiKey: apiKey,
            instructions: instructions,
            prompt: prompt
        )
    }

    func makeTextStream(
        configuration: AIProviderConfiguration,
        apiKey: String,
        instructions: String,
        prompt: String
    ) throws -> AsyncThrowingStream<String, Error> {
        let configuration = try configuration.validated()
        let request = try requestBuilder.makeStreamingRequest(
            configuration: configuration,
            apiKey: apiKey,
            instructions: instructions,
            prompt: prompt
        )
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(128)
        )
        let worker = Task {
            await Self.consume(
                request: request,
                configuration: configuration,
                session: session,
                continuation: continuation
            )
        }
        continuation.onTermination = { @Sendable _ in worker.cancel() }
        return stream
    }

    @concurrent
    private static func consume(
        request: URLRequest,
        configuration: AIProviderConfiguration,
        session: URLSession,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw AIProviderError.invalidHTTPResponse
            }
            guard (200...299).contains(response.statusCode) else {
                let requestID =
                    response.value(forHTTPHeaderField: "x-request-id")
                    ?? response.value(forHTTPHeaderField: "request-id")
                throw AIProviderError.providerRejected(
                    statusCode: response.statusCode,
                    requestID: requestID.map {
                        String(decoding: $0.utf8.prefix(128), as: UTF8.self)
                    }
                )
            }

            var parser = ServerSentEventParser()
            let decoder = AIProviderStreamDecoder()
            var lineBytes: [UInt8] = []
            lineBytes.reserveCapacity(256)
            var wireBytes = 0
            var outputBytes = 0

            for try await byte in bytes {
                try Task.checkCancellation()
                wireBytes += 1
                guard wireBytes <= Self.maximumWireBytes else {
                    throw AIProviderError.responseTooLarge(maximumBytes: Self.maximumWireBytes)
                }

                if byte == 0x0A {
                    if lineBytes.last == 0x0D { lineBytes.removeLast() }
                    let line = String(decoding: lineBytes, as: UTF8.self)
                    lineBytes.removeAll(keepingCapacity: true)
                    if let event = try parser.consume(line: line) {
                        let decoded = try decoder.decode(event, configuration: configuration)
                        if try emit(
                            decoded,
                            outputBytes: &outputBytes,
                            continuation: continuation
                        ) {
                            return
                        }
                    }
                } else {
                    lineBytes.append(byte)
                    guard lineBytes.count <= ServerSentEventParser.maximumEventBytes else {
                        throw AIProviderError.responseTooLarge(
                            maximumBytes: ServerSentEventParser.maximumEventBytes
                        )
                    }
                }
            }

            if !lineBytes.isEmpty {
                let line = String(decoding: lineBytes, as: UTF8.self)
                if let event = try parser.consume(line: line) {
                    let decoded = try decoder.decode(event, configuration: configuration)
                    if try emit(
                        decoded,
                        outputBytes: &outputBytes,
                        continuation: continuation
                    ) {
                        return
                    }
                }
            }
            if let event = parser.finish() {
                _ = try emit(
                    decoder.decode(event, configuration: configuration),
                    outputBytes: &outputBytes,
                    continuation: continuation
                )
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private static func emit(
        _ event: AIProviderDecodedEvent,
        outputBytes: inout Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws -> Bool {
        switch event {
        case .ignored:
            return false
        case .done:
            continuation.finish()
            return true
        case .text(let text):
            outputBytes += text.utf8.count
            guard outputBytes <= Self.maximumOutputBytes else {
                throw AIProviderError.responseTooLarge(maximumBytes: Self.maximumOutputBytes)
            }
            switch continuation.yield(text) {
            case .enqueued:
                return false
            case .dropped:
                throw AIProviderError.responseTooLarge(maximumBytes: Self.maximumOutputBytes)
            case .terminated:
                throw CancellationError()
            @unknown default:
                throw AIProviderError.malformedResponse
            }
        }
    }
}
