import Foundation

/// Framing failures. Every case carries only sizes, never header or body
/// bytes — framing errors must never leak document/server payload content.
nonisolated enum JSONRPCFramingError: Error, Equatable {
    case headerTooLarge(limitBytes: Int)
    case missingContentLength
    case malformedHeader
    case bodyTooLarge(declaredBytes: Int, limitBytes: Int)
}

/// Writes the `Content-Length` framing LSP/JSON-RPC-over-stdio expects.
/// Only `Content-Length` is emitted; no other header.
nonisolated enum JSONRPCFrameEncoder {
    static func encode(body: Data) -> Data {
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        return framed
    }
}

/// Pure, incremental decoder for `Content-Length`-framed JSON-RPC bodies.
/// No I/O: callers feed it arbitrary byte chunks via `consume(_:)` and it
/// returns zero or more complete bodies, buffering partial frames across
/// calls. Mirrors the incremental style of `ServerSentEventParser`.
nonisolated struct JSONRPCFrameDecoder: Sendable {
    private enum State: Sendable {
        case readingHeaders
        case readingBody(expected: Int)
    }

    /// `\r\n\r\n`: the strict header/body separator.
    private static let headerSeparator = Data([0x0D, 0x0A, 0x0D, 0x0A])

    private let maximumHeaderBytes: Int
    private let maximumBodyBytes: Int
    private var buffer = Data()
    private var state: State = .readingHeaders

    init(maximumHeaderBytes: Int = 16 * 1_024, maximumBodyBytes: Int = 32 * 1_024 * 1_024) {
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumBodyBytes = maximumBodyBytes
    }

    /// Appends `chunk` to the internal buffer and returns every complete
    /// body that becomes available as a result. A body `Data` returned here
    /// is always a fresh copy, never a slice sharing storage with the
    /// internal buffer — `Data` slices preserve their parent's indices, so
    /// retaining one instead of copying it risks an out-of-bounds trap the
    /// next time the buffer is re-based.
    mutating func consume(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var results: [Data] = []
        while true {
            switch state {
            case .readingHeaders:
                guard let separatorRange = buffer.range(of: Self.headerSeparator) else {
                    if buffer.count > maximumHeaderBytes {
                        throw JSONRPCFramingError.headerTooLarge(limitBytes: maximumHeaderBytes)
                    }
                    return results
                }
                let headerBlock = buffer[buffer.startIndex..<separatorRange.lowerBound]
                let contentLength = try Self.parseContentLength(
                    headerBlock: headerBlock,
                    maximumBodyBytes: maximumBodyBytes
                )
                // Re-base: copy the remainder into a fresh `Data` so its
                // indices start at 0 again.
                buffer = Data(buffer[separatorRange.upperBound...])
                state = .readingBody(expected: contentLength)
            case .readingBody(let expected):
                guard buffer.count >= expected else { return results }
                let bodyEnd = buffer.index(buffer.startIndex, offsetBy: expected)
                let body = Data(buffer[buffer.startIndex..<bodyEnd])
                buffer = Data(buffer[bodyEnd...])
                results.append(body)
                state = .readingHeaders
            }
        }
    }

    private static func parseContentLength(headerBlock: Data, maximumBodyBytes: Int) throws -> Int {
        let headerText = String(decoding: headerBlock, as: UTF8.self)
        var contentLength: Int?
        for line in headerText.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = trimmedASCIISpaces(line[line.startIndex..<colonIndex]).lowercased()
            guard name == "content-length" else { continue }
            let rawValue = trimmedASCIISpaces(line[line.index(after: colonIndex)...])
            guard let value = Int(rawValue), value >= 0 else {
                throw JSONRPCFramingError.malformedHeader
            }
            contentLength = value
        }
        guard let contentLength else {
            throw JSONRPCFramingError.missingContentLength
        }
        guard contentLength <= maximumBodyBytes else {
            throw JSONRPCFramingError.bodyTooLarge(
                declaredBytes: contentLength,
                limitBytes: maximumBodyBytes
            )
        }
        return contentLength
    }

    private static func trimmedASCIISpaces(_ value: Substring) -> Substring {
        var value = value
        while value.first == " " { value.removeFirst() }
        while value.last == " " { value.removeLast() }
        return value
    }
}
