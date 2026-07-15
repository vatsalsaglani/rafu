import Foundation
import Testing

@testable import RafuApp

@Test("Encoder emits exactly the Content-Length prefix and nothing else")
func frameEncoderEmitsExactPrefix() {
    let framed = JSONRPCFrameEncoder.encode(body: Data("{}".utf8))
    #expect(framed == Data("Content-Length: 2\r\n\r\n{}".utf8))
}

@Test("A frame encoded then decoded round-trips to the original body")
func frameRoundTrips() throws {
    let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
    var decoder = JSONRPCFrameDecoder()
    let bodies = try decoder.consume(JSONRPCFrameEncoder.encode(body: body))
    #expect(bodies == [body])
}

@Test("One chunk containing two back-to-back frames yields two bodies")
func decoderYieldsTwoBodiesFromOneChunk() throws {
    let first = Data(#"{"a":1}"#.utf8)
    let second = Data(#"{"b":2}"#.utf8)
    var chunk = JSONRPCFrameEncoder.encode(body: first)
    chunk.append(JSONRPCFrameEncoder.encode(body: second))

    var decoder = JSONRPCFrameDecoder()
    let bodies = try decoder.consume(chunk)
    #expect(bodies == [first, second])
}

@Test("Feeding a frame one byte at a time yields exactly one body, at the final byte")
func decoderYieldsExactlyOneBodyOnFinalByte() throws {
    let body = Data(#"{"value":"hi"}"#.utf8)
    let framed = JSONRPCFrameEncoder.encode(body: body)
    var decoder = JSONRPCFrameDecoder()

    var results: [Data] = []
    for (index, byte) in framed.enumerated() {
        let bodies = try decoder.consume(Data([byte]))
        results.append(contentsOf: bodies)
        if index < framed.count - 1 {
            #expect(bodies.isEmpty)
        }
    }
    #expect(results == [body])
}

@Test("A chunk boundary in the middle of a header name is handled correctly")
func decoderHandlesChunkBoundaryMidHeaderName() throws {
    let body = Data(#"{"ok":true}"#.utf8)
    let framed = JSONRPCFrameEncoder.encode(body: body)
    // "Content-Length" is at offset 0; split inside the header name.
    let splitIndex = framed.index(framed.startIndex, offsetBy: 4)
    var decoder = JSONRPCFrameDecoder()
    var results = try decoder.consume(Data(framed[framed.startIndex..<splitIndex]))
    #expect(results.isEmpty)
    results = try decoder.consume(Data(framed[splitIndex...]))
    #expect(results == [body])
}

@Test("A chunk boundary in the middle of the body is handled correctly")
func decoderHandlesChunkBoundaryMidBody() throws {
    let body = Data(#"{"greeting":"hello world"}"#.utf8)
    let framed = JSONRPCFrameEncoder.encode(body: body)
    let headerEnd = framed.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))!.upperBound
    let splitIndex = framed.index(headerEnd, offsetBy: 5)

    var decoder = JSONRPCFrameDecoder()
    var results = try decoder.consume(Data(framed[framed.startIndex..<splitIndex]))
    #expect(results.isEmpty)
    results = try decoder.consume(Data(framed[splitIndex...]))
    #expect(results == [body])
}

@Test("A lowercase content-length header name is accepted")
func decoderAcceptsLowercaseHeaderName() throws {
    let body = Data("{}".utf8)
    let framed = Data("content-length: 2\r\n\r\n".utf8) + body
    var decoder = JSONRPCFrameDecoder()
    #expect(try decoder.consume(framed) == [body])
}

@Test("An extra unrelated header is ignored")
func decoderIgnoresExtraHeaders() throws {
    let body = Data("{}".utf8)
    let framed =
        Data("Content-Type: application/vscode-jsonrpc\r\nContent-Length: 2\r\n\r\n".utf8) + body
    var decoder = JSONRPCFrameDecoder()
    #expect(try decoder.consume(framed) == [body])
}

@Test("A missing Content-Length header throws missingContentLength")
func decoderThrowsOnMissingContentLength() {
    var decoder = JSONRPCFrameDecoder()
    #expect(throws: JSONRPCFramingError.missingContentLength) {
        _ = try decoder.consume(Data("Content-Type: text/plain\r\n\r\n".utf8))
    }
}

@Test("A non-numeric Content-Length value throws malformedHeader")
func decoderThrowsOnNonNumericContentLength() {
    var decoder = JSONRPCFrameDecoder()
    #expect(throws: JSONRPCFramingError.malformedHeader) {
        _ = try decoder.consume(Data("Content-Length: abc\r\n\r\n".utf8))
    }
}

@Test("A declared Content-Length over the cap throws bodyTooLarge immediately")
func decoderThrowsOnOversizedDeclaredLength() {
    var decoder = JSONRPCFrameDecoder(maximumHeaderBytes: 1_024, maximumBodyBytes: 16)
    #expect(
        throws: JSONRPCFramingError.bodyTooLarge(declaredBytes: 17, limitBytes: 16)
    ) {
        _ = try decoder.consume(Data("Content-Length: 17\r\n\r\n".utf8))
    }
}

@Test("Headers that never terminate and exceed the cap throw headerTooLarge")
func decoderThrowsOnOversizedHeaders() {
    var decoder = JSONRPCFrameDecoder(maximumHeaderBytes: 8, maximumBodyBytes: 1_024)
    #expect(throws: JSONRPCFramingError.headerTooLarge(limitBytes: 8)) {
        _ = try decoder.consume(Data("X-Filler: 0123456789\r\n".utf8))
    }
}

@Test("Content-Length: 0 yields an empty body")
func decoderYieldsEmptyBodyForZeroLength() throws {
    var decoder = JSONRPCFrameDecoder()
    let bodies = try decoder.consume(Data("Content-Length: 0\r\n\r\n".utf8))
    #expect(bodies == [Data()])
}
