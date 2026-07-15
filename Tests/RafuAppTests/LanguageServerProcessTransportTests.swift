import Foundation
import Testing

@testable import RafuApp

private struct EchoPayload: Codable, Equatable {
    let value: String
}

@Test("BoundedByteRingBuffer keeps sub-capacity appends intact")
func ringBufferKeepsSubCapacityAppendsIntact() {
    let buffer = BoundedByteRingBuffer(capacityBytes: 16)
    buffer.append(Data("hello".utf8))
    buffer.append(Data(" world".utf8))
    #expect(buffer.snapshot() == Data("hello world".utf8))
}

@Test("BoundedByteRingBuffer trims the oldest bytes on overflow")
func ringBufferTrimsOldestBytesOnOverflow() {
    let buffer = BoundedByteRingBuffer(capacityBytes: 5)
    buffer.append(Data("abcde".utf8))
    buffer.append(Data("fg".utf8))
    // "abcde" + "fg" = "abcdefg" (7 bytes); trimming to the 5-byte capacity
    // keeps only the last 5 bytes: "cdefg".
    #expect(buffer.snapshot() == Data("cdefg".utf8))
}

@Test("BoundedByteRingBuffer snapshot returns an independent copy")
func ringBufferSnapshotIsACopy() {
    let buffer = BoundedByteRingBuffer(capacityBytes: 32)
    buffer.append(Data("hello".utf8))
    var snapshot = buffer.snapshot()
    snapshot.append(Data(" mutated".utf8))
    #expect(buffer.snapshot() == Data("hello".utf8))
    #expect(snapshot == Data("hello mutated".utf8))
}

@Test("Spawning /bin/cat echoes a framed message back and exits cleanly")
func processTransportEchoesFramedMessageViaCat() async throws {
    let specification = LanguageServerLaunchSpecification(
        executableURL: URL(fileURLWithPath: "/bin/cat"),
        arguments: [],
        environment: nil,
        currentDirectoryURL: nil
    )
    let transport = LanguageServerProcessTransport(specification: specification)

    // A failed `#require`/thrown error below must still close the process
    // — never leak a live `cat` — so every exit path routes through this
    // `catch` before rethrowing.
    do {
        try await transport.startProcess()
        var iterator = await transport.receive().makeAsyncIterator()

        let payload = try JSONEncoder().encode(EchoPayload(value: "ping"))
        try await transport.send(JSONRPCFrameEncoder.encode(body: payload))

        var decoder = JSONRPCFrameDecoder()
        var echoedBody: Data?
        while echoedBody == nil {
            guard let chunk = try await iterator.next() else { break }
            echoedBody = try decoder.consume(chunk).first
        }
        let body = try #require(echoedBody)
        let echoed = try JSONDecoder().decode(EchoPayload.self, from: body)
        #expect(echoed.value == "ping")

        await transport.close()
        let status = await transport.exitStatus()
        #expect(status.code == 0)
    } catch {
        await transport.close()
        throw error
    }
}
