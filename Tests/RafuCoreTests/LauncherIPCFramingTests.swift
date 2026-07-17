import Foundation
import RafuCore
import Testing

@Suite("Launcher IPC framing and JSON codec")
struct LauncherIPCFramingTests {
    @Test("Every request kind round-trips through framing and JSON")
    func everyRequestKindRoundTrips() throws {
        let request = LauncherOpenRequest(
            target: .local(path: "/private/tmp/project"),
            sourceLocation: SourceLocation(line: 42, column: 8),
            activationPolicy: .newWindow,
            wait: true
        )
        let envelopes = [
            LauncherIPCEnvelope(kind: .handshake, requestID: "handshake"),
            LauncherIPCEnvelope(kind: .openFolder, payload: request, requestID: "open"),
            LauncherIPCEnvelope(kind: .goto, payload: request, requestID: "goto"),
        ]

        for envelope in envelopes {
            var decoder = LauncherIPCFrameDecoder()
            let bodies = try decoder.consume(LauncherIPCCodec.encode(envelope))
            #expect(bodies.count == 1)
            let decoded = try LauncherIPCCodec.decode(
                LauncherIPCEnvelope.self,
                from: bodies[0]
            )
            #expect(decoded == envelope)
            try decoder.finish()
        }
    }

    @Test("Accepted and rejected responses round-trip")
    func responsesRoundTrip() throws {
        let responses: [LauncherIPCResponse] = [
            .accepted(workspaceMatched: true, windowFocused: true, waitSupported: false),
            .rejected(reason: "unsupported request kind"),
        ]

        for response in responses {
            var decoder = LauncherIPCFrameDecoder()
            let body = try #require(decoder.consume(LauncherIPCCodec.encode(response)).first)
            #expect(try LauncherIPCCodec.decode(LauncherIPCResponse.self, from: body) == response)
        }
    }

    @Test("A frame reassembles from every possible partial chunk boundary")
    func partialChunkReassembly() throws {
        let envelope = LauncherIPCEnvelope(kind: .handshake, requestID: "partial")
        let frame = try LauncherIPCCodec.encode(envelope)

        for split in 0...frame.count {
            var decoder = LauncherIPCFrameDecoder()
            var bodies = try decoder.consume(Data(frame.prefix(split)))
            bodies.append(contentsOf: try decoder.consume(Data(frame.dropFirst(split))))
            #expect(bodies.count == 1)
            #expect(
                try LauncherIPCCodec.decode(LauncherIPCEnvelope.self, from: bodies[0])
                    == envelope
            )
        }
    }

    @Test("Back-to-back frames yield independently rebased bodies")
    func multipleFramesAndFreshCopies() throws {
        let first = LauncherIPCEnvelope(kind: .handshake, requestID: "first")
        let second = LauncherIPCEnvelope(kind: .handshake, requestID: "second")
        var chunk = try LauncherIPCCodec.encode(first)
        chunk.append(try LauncherIPCCodec.encode(second))

        var decoder = LauncherIPCFrameDecoder()
        let bodies = try decoder.consume(chunk)
        #expect(bodies.count == 2)
        #expect(try LauncherIPCCodec.decode(LauncherIPCEnvelope.self, from: bodies[0]) == first)
        #expect(try LauncherIPCCodec.decode(LauncherIPCEnvelope.self, from: bodies[1]) == second)
    }

    @Test("An oversized body is rejected by the encoder and decoder")
    func oversizedBodyRejected() throws {
        let oversized = Data(repeating: 0, count: LauncherIPCProtocol.maxFrameBytes + 1)
        #expect(
            throws: LauncherIPCFramingError.bodyTooLarge(
                declaredBytes: oversized.count,
                limitBytes: LauncherIPCProtocol.maxFrameBytes
            )
        ) {
            _ = try LauncherIPCFrameEncoder.encode(body: oversized)
        }

        let declared = UInt32(LauncherIPCProtocol.maxFrameBytes + 1)
        let header = Data([
            0x52, 0x41, 0x46, 0x55,
            UInt8(LauncherIPCProtocol.wireVersion),
            UInt8((declared >> 24) & 0xFF),
            UInt8((declared >> 16) & 0xFF),
            UInt8((declared >> 8) & 0xFF),
            UInt8(declared & 0xFF),
        ])
        var decoder = LauncherIPCFrameDecoder()
        #expect(
            throws: LauncherIPCFramingError.bodyTooLarge(
                declaredBytes: Int(declared),
                limitBytes: LauncherIPCProtocol.maxFrameBytes
            )
        ) {
            _ = try decoder.consume(header)
        }
    }

    @Test("Truncated header and body are rejected at end-of-stream")
    func truncatedFramesRejected() throws {
        var headerDecoder = LauncherIPCFrameDecoder()
        _ = try headerDecoder.consume(Data([0x52, 0x41, 0x46]))
        #expect(
            throws: LauncherIPCFramingError.truncatedFrame(receivedBytes: 3, expectedBytes: 9)
        ) {
            try headerDecoder.finish()
        }

        let complete = try LauncherIPCCodec.encode(
            LauncherIPCEnvelope(kind: .handshake, requestID: "truncated")
        )
        let partial = Data(complete.dropLast())
        var bodyDecoder = LauncherIPCFrameDecoder()
        _ = try bodyDecoder.consume(partial)
        #expect(throws: LauncherIPCFramingError.self) {
            try bodyDecoder.finish()
        }
    }

    @Test("Garbage magic and incompatible wire version are typed failures")
    func invalidHeadersRejected() {
        var garbageDecoder = LauncherIPCFrameDecoder()
        #expect(throws: LauncherIPCFramingError.invalidMagic) {
            _ = try garbageDecoder.consume(Data(repeating: 0, count: 9))
        }

        var versionDecoder = LauncherIPCFrameDecoder()
        #expect(
            throws: LauncherIPCFramingError.unsupportedWireVersion(
                received: 99,
                supported: LauncherIPCProtocol.wireVersion
            )
        ) {
            _ = try versionDecoder.consume(
                Data([0x52, 0x41, 0x46, 0x55, 99, 0, 0, 0, 0])
            )
        }
    }

    @Test("Unknown JSON fields are tolerated")
    func unknownFieldsTolerated() throws {
        let body = Data(
            #"{"wireVersion":1,"protocolVersion":1,"requestID":"future","kind":"handshake","payload":null,"futureField":{"value":7}}"#
                .utf8
        )
        let decoded = try LauncherIPCCodec.decode(LauncherIPCEnvelope.self, from: body)
        #expect(decoded.kind == .handshake)
        #expect(decoded.requestID == "future")
    }

    @Test("Unknown request kind is preserved as a rejectable sentinel")
    func unknownKindPreserved() throws {
        let body = Data(
            #"{"wireVersion":1,"protocolVersion":1,"requestID":"future","kind":"futureAction","payload":null}"#
                .utf8
        )
        let decoded = try LauncherIPCCodec.decode(LauncherIPCEnvelope.self, from: body)
        #expect(decoded.kind == .unknown("futureAction"))
    }

    @Test("Malformed JSON is a content-free codec failure")
    func malformedJSONRejected() {
        #expect(throws: LauncherIPCCodecError.malformedJSON) {
            _ = try LauncherIPCCodec.decode(
                LauncherIPCEnvelope.self,
                from: Data("not-json".utf8)
            )
        }
    }
}
