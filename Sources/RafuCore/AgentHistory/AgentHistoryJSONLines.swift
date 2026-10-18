import Foundation

/// Bounded JSON Lines reading. Every read has a byte limit, partial lines at
/// a cut are dropped, and malformed lines are skipped by the parsers.
enum AgentHistoryFileReader {
    /// The head and tail of one file, split into complete lines.
    struct Sample {
        var headLines: [Data]
        var tailLines: [Data]
        /// The whole file was read, so counts are exact.
        var coversWholeFile: Bool
        var sampledBytes: Int
    }

    static let newline: UInt8 = 0x0A

    /// Reads the first `headBytes` and the last `tailBytes` of a file. When
    /// the head holds no complete line (one very long first entry), the head
    /// grows once, up to `maximumHeadBytes`.
    static func sample(
        _ url: URL, size: Int64, headBytes: Int, tailBytes: Int, maximumHeadBytes: Int
    ) throws -> Sample {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if size <= Int64(headBytes + tailBytes) {
            let data = try handle.read(upToCount: headBytes + tailBytes) ?? Data()
            return Sample(
                headLines: lines(in: data, dropFirst: false, dropLast: false),
                tailLines: [], coversWholeFile: true, sampledBytes: data.count)
        }
        var head = try handle.read(upToCount: headBytes) ?? Data()
        if !head.contains(newline), maximumHeadBytes > headBytes {
            let more = try handle.read(upToCount: maximumHeadBytes - headBytes) ?? Data()
            head.append(more)
        }
        let headLines = lines(in: head, dropFirst: false, dropLast: true)
        let tailOffset = max(UInt64(head.count), UInt64(size) - UInt64(tailBytes))
        try handle.seek(toOffset: tailOffset)
        let tail = try handle.read(upToCount: tailBytes) ?? Data()
        let tailLines = lines(in: tail, dropFirst: tailOffset > UInt64(head.count), dropLast: false)
        let covers = Int64(head.count + tail.count) >= size
        return Sample(
            headLines: headLines, tailLines: tailLines, coversWholeFile: covers,
            sampledBytes: head.count + tail.count)
    }

    /// Calls `body` for each complete line of the first `maxBytes` bytes. A
    /// `false` return stops early. Checks for cancellation between chunks.
    /// Returns `true` when the byte limit stopped the read before the end.
    @discardableResult
    static func forEachLine(
        _ url: URL, maxBytes: Int, chunkSize: Int = 1 << 20, _ body: (Data) throws -> Bool
    ) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data()
        var consumed = 0
        while consumed < maxBytes {
            try Task.checkCancellation()
            let count = min(chunkSize, maxBytes - consumed)
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                // End of file: the final line may lack a newline.
                if !buffer.isEmpty { _ = try body(buffer) }
                return false
            }
            consumed += chunk.count
            buffer.append(chunk)
            var start = buffer.startIndex
            while let end = buffer[start...].firstIndex(of: newline) {
                let line = buffer[start..<end]
                if !line.isEmpty, try !body(Data(line)) { return false }
                start = buffer.index(after: end)
            }
            buffer = Data(buffer[start...])
        }
        // Limit reached. A trailing partial line is dropped.
        let next = try handle.read(upToCount: 1) ?? Data()
        return !next.isEmpty || !buffer.isEmpty
    }

    static func lines(in data: Data, dropFirst: Bool, dropLast: Bool) -> [Data] {
        var parts = data.split(separator: newline, omittingEmptySubsequences: false)
        if dropFirst, !parts.isEmpty { parts.removeFirst() }
        if dropLast, !parts.isEmpty, data.last != newline { parts.removeLast() }
        return parts.filter { !$0.isEmpty }.map { Data($0) }
    }
}

/// Tolerant accessors over `JSONSerialization` output.
enum AgentHistoryJSON {
    static func object(_ line: Data) -> [String: Any]? {
        guard let first = line.first(where: { $0 != 0x20 && $0 != 0x09 }), first == 0x7B else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    static func object(jsonText: String) -> [String: Any]? {
        guard let data = jsonText.data(using: .utf8) else { return nil }
        return object(data)
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func bool(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(exactly: number.rounded()) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(text)
    }

    /// Compact, sorted-key JSON for tool arguments; `nil` when not encodable.
    static func compactText(_ value: Any) -> String? {
        if let text = value as? String { return text }
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Bounds and cleans text taken from transcripts.
public enum AgentHistoryText {
    /// One line: control characters and line breaks become spaces, runs of
    /// whitespace collapse, and the result is cut to `limit` characters.
    public static func singleLine(_ text: String, limit: Int) -> String {
        var result = ""
        result.reserveCapacity(min(text.utf8.count, limit * 2))
        var lastWasSpace = true
        var count = 0
        for scalar in text.unicodeScalars {
            let isSpace =
                CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
            if isSpace {
                if !lastWasSpace {
                    result.unicodeScalars.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            result.unicodeScalars.append(scalar)
            lastWasSpace = false
            count += 1
            if count >= limit * 2 { break }
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(max(limit - 1, 0))) + "…"
    }

    /// Cuts `text` to `limit` characters. The flag tells whether it was cut.
    static func bounded(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)), true)
    }
}
