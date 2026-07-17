import Foundation

/// Framing failures carry only byte counts or version numbers. They never
/// retain or describe frame bytes, because launcher payloads can contain
/// private filesystem paths.
public enum LauncherIPCFramingError: Error, Equatable, Sendable {
    case bodyTooLarge(declaredBytes: Int, limitBytes: Int)
    case invalidMagic
    case unsupportedWireVersion(received: Int, supported: Int)
    case truncatedFrame(receivedBytes: Int, expectedBytes: Int)
}

/// JSON failures deliberately omit the underlying encoder/decoder message so
/// malformed payload content cannot leak into diagnostics or unified logs.
public enum LauncherIPCCodecError: Error, Equatable, Sendable {
    case malformedJSON
}

/// Encodes the fixed launcher header (`RAFU`, wire version, big-endian body
/// length) around an already-encoded JSON body.
public enum LauncherIPCFrameEncoder {
    public static let headerByteCount = 9

    public static func encode(body: Data) throws -> Data {
        guard body.count <= LauncherIPCProtocol.maxFrameBytes else {
            throw LauncherIPCFramingError.bodyTooLarge(
                declaredBytes: body.count,
                limitBytes: LauncherIPCProtocol.maxFrameBytes
            )
        }

        var frame = Data([0x52, 0x41, 0x46, 0x55])  // "RAFU"
        frame.append(UInt8(LauncherIPCProtocol.wireVersion))
        let length = UInt32(body.count)
        frame.append(UInt8((length >> 24) & 0xFF))
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(body)
        return frame
    }
}

/// Pure incremental decoder for launcher frames. Callers may feed arbitrary
/// chunks and receive zero or more complete JSON bodies. Returned bodies and
/// the retained remainder are always fresh `Data` values with rebased indices.
public struct LauncherIPCFrameDecoder: Sendable {
    private static let magic = [UInt8](arrayLiteral: 0x52, 0x41, 0x46, 0x55)
    private var buffer = Data()

    public init() {}

    public mutating func consume(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var bodies: [Data] = []

        while buffer.count >= LauncherIPCFrameEncoder.headerByteCount {
            let bodyLength = try parseHeader()
            let frameLength = LauncherIPCFrameEncoder.headerByteCount + bodyLength
            guard buffer.count >= frameLength else { return bodies }

            let bodyStart = buffer.index(
                buffer.startIndex,
                offsetBy: LauncherIPCFrameEncoder.headerByteCount
            )
            let bodyEnd = buffer.index(bodyStart, offsetBy: bodyLength)
            bodies.append(Data(buffer[bodyStart..<bodyEnd]))
            buffer = Data(buffer[bodyEnd...])
        }

        return bodies
    }

    /// Signals end-of-stream. An incomplete header or body is rejected rather
    /// than silently discarded; an empty decoder finishes successfully.
    public mutating func finish() throws {
        guard !buffer.isEmpty else { return }
        guard buffer.count >= LauncherIPCFrameEncoder.headerByteCount else {
            throw LauncherIPCFramingError.truncatedFrame(
                receivedBytes: buffer.count,
                expectedBytes: LauncherIPCFrameEncoder.headerByteCount
            )
        }

        let bodyLength = try parseHeader()
        throw LauncherIPCFramingError.truncatedFrame(
            receivedBytes: buffer.count,
            expectedBytes: LauncherIPCFrameEncoder.headerByteCount + bodyLength
        )
    }

    private func parseHeader() throws -> Int {
        let bytes = [UInt8](buffer.prefix(LauncherIPCFrameEncoder.headerByteCount))
        guard Array(bytes.prefix(4)) == Self.magic else {
            throw LauncherIPCFramingError.invalidMagic
        }

        let receivedVersion = Int(bytes[4])
        guard receivedVersion == LauncherIPCProtocol.wireVersion else {
            throw LauncherIPCFramingError.unsupportedWireVersion(
                received: receivedVersion,
                supported: LauncherIPCProtocol.wireVersion
            )
        }

        let declaredLength =
            (UInt32(bytes[5]) << 24)
            | (UInt32(bytes[6]) << 16)
            | (UInt32(bytes[7]) << 8)
            | UInt32(bytes[8])
        let bodyLength = Int(declaredLength)
        guard bodyLength <= LauncherIPCProtocol.maxFrameBytes else {
            throw LauncherIPCFramingError.bodyTooLarge(
                declaredBytes: bodyLength,
                limitBytes: LauncherIPCProtocol.maxFrameBytes
            )
        }
        return bodyLength
    }
}

/// JSON body encoding/decoding shared by the CLI client and app listener.
public enum LauncherIPCCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            body = try encoder.encode(value)
        } catch {
            throw LauncherIPCCodecError.malformedJSON
        }
        return try LauncherIPCFrameEncoder.encode(body: body)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw LauncherIPCCodecError.malformedJSON
        }
    }
}
