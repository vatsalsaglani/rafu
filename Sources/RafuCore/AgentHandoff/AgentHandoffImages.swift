import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif

// Agent handoff (round 4): images found in a Claude Code or Codex transcript.
// Everything here is read-only toward the transcript. Image bytes are decoded
// only when the user opens the review sheet, one bounded pass at a time.

/// The image types Rafu copies into a handoff folder. The type comes from
/// the first bytes of the decoded data, never from a claimed media type.
public enum AgentHandoffImageFormat: String, CaseIterable, Sendable {
    case png
    case jpeg
    case gif
    case webp

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .gif: "gif"
        case .webp: "webp"
        }
    }

    /// Detects a format from magic bytes: PNG, JPEG, GIF87a/89a, RIFF/WEBP.
    public static func detect(_ data: Data) -> AgentHandoffImageFormat? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8,
            Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        {
            return .png
        }
        if bytes.count >= 3, Array(bytes[0..<3]) == [0xFF, 0xD8, 0xFF] { return .jpeg }
        if bytes.count >= 6,
            Array(bytes[0..<6]) == [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]
                || Array(bytes[0..<6]) == [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]
        {
            return .gif
        }
        if bytes.count >= 12, Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46],
            Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50]
        {
            return .webp
        }
        return nil
    }
}

/// The bounds for the images of one handoff.
public enum AgentHandoffImageLimits {
    /// Most images one handoff can hold. The newest ones win.
    public static let maximumImages = 20
    /// Most bytes of one image after decoding.
    public static let maximumDecodedBytes = 5 << 20
}

/// Why an image is not in the handoff. Shown to the user as a short note.
public enum AgentHandoffImageSkipReason: String, Sendable, Equatable {
    case tooLarge
    case badEncoding
    case unsupportedType
    case remoteURL
    case missingFile
    case unreadable
    case overLimit
    case excludedByUser
    case notLoaded

    public var note: String {
        switch self {
        case .tooLarge: "larger than 5 MB"
        case .badEncoding: "could not be decoded"
        case .unsupportedType: "not a PNG, JPEG, GIF, or WebP image"
        case .remoteURL: "a web address, which Rafu does not fetch"
        case .missingFile: "the file no longer exists"
        case .unreadable: "the file could not be read"
        case .overLimit: "more than 20 images; only the newest are kept"
        case .excludedByUser: "left out in the review"
        case .notLoaded: "not loaded"
        }
    }
}

/// Where the bytes of one image come from, found without decoding them.
enum AgentHandoffRawImage: Equatable {
    /// Base64 text from a Claude `image` block or a Codex `data:` URL.
    case base64(String)
    /// A local file path named by a transcript.
    case localFile(String)
    /// A web address. Never fetched.
    case remote
    /// A block with no usable data.
    case unusable
}

/// Where an image sits in a transcript line, for the later decode.
public enum AgentHandoffImageLocation: Equatable, Sendable {
    /// The `ordinal`-th image of the JSON line that starts at `lineOffset`.
    case embedded(lineOffset: UInt64, lineLength: Int, ordinal: Int)
    case localFile(path: String)
}

/// A pointer to one image. It holds no image bytes.
public struct AgentHandoffImageRef: Identifiable, Equatable, Sendable {
    /// Unique within one loaded conversation, in transcript order.
    public let id: Int
    public let location: AgentHandoffImageLocation
    /// `true` when the image came from a tool result, not from a message.
    public let isToolResult: Bool
    /// The size of the base64 text, when known. An estimate for the sheet.
    public let encodedLength: Int?
    /// The reason the loader already knows the image cannot be used.
    public let knownSkip: AgentHandoffImageSkipReason?

    public init(
        id: Int, location: AgentHandoffImageLocation, isToolResult: Bool,
        encodedLength: Int? = nil, knownSkip: AgentHandoffImageSkipReason? = nil
    ) {
        self.id = id
        self.location = location
        self.isToolResult = isToolResult
        self.encodedLength = encodedLength
        self.knownSkip = knownSkip
    }

    /// An estimate of the decoded size.
    public var estimatedBytes: Int? {
        encodedLength.map { $0 / 4 * 3 }
    }
}

/// One decoded, verified image.
public struct AgentHandoffDecodedImage: Equatable, Sendable {
    public let data: Data
    public let format: AgentHandoffImageFormat
    public let sha256: String

    public init(data: Data, format: AgentHandoffImageFormat, sha256: String) {
        self.data = data
        self.format = format
        self.sha256 = sha256
    }
}

public enum AgentHandoffImageResult: Equatable, Sendable {
    case image(AgentHandoffDecodedImage)
    case skipped(AgentHandoffImageSkipReason)
}

/// SHA-256 as lowercase hex. CryptoKit on Apple platforms; a small pure
/// implementation elsewhere (the Linux checks).
enum AgentHandoffDigest {
    static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
            return PortableSHA256.hex(data)
        #endif
    }
}

#if !canImport(CryptoKit)
    enum PortableSHA256 {
        private static let k: [UInt32] = [
            0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1,
            0x923f_82a4, 0xab1c_5ed5, 0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
            0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174, 0xe49b_69c1, 0xefbe_4786,
            0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
            0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147,
            0x06ca_6351, 0x1429_2967, 0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
            0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85, 0xa2bf_e8a1, 0xa81a_664b,
            0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
            0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a,
            0x5b9c_ca4f, 0x682e_6ff3, 0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
            0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
        ]

        static func hex(_ data: Data) -> String {
            var h: [UInt32] = [
                0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c,
                0x1f83_d9ab, 0x5be0_cd19,
            ]
            var message = [UInt8](data)
            let bitLength = UInt64(message.count) * 8
            message.append(0x80)
            while message.count % 64 != 56 { message.append(0) }
            for shift in stride(from: 56, through: 0, by: -8) {
                message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
            }
            var w = [UInt32](repeating: 0, count: 64)
            for chunk in stride(from: 0, to: message.count, by: 64) {
                for i in 0..<16 {
                    let base = chunk + i * 4
                    w[i] =
                        UInt32(message[base]) << 24 | UInt32(message[base + 1]) << 16
                        | UInt32(message[base + 2]) << 8 | UInt32(message[base + 3])
                }
                for i in 16..<64 {
                    let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                    let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                    w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
                }
                var a = h[0]
                var b = h[1]
                var c = h[2]
                var d = h[3]
                var e = h[4]
                var f = h[5]
                var g = h[6]
                var hh = h[7]
                for i in 0..<64 {
                    let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                    let ch = (e & f) ^ (~e & g)
                    let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                    let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                    let maj = (a & b) ^ (a & c) ^ (b & c)
                    let t2 = s0 &+ maj
                    hh = g
                    g = f
                    f = e
                    e = d &+ t1
                    d = c
                    c = b
                    b = a
                    a = t1 &+ t2
                }
                h[0] = h[0] &+ a
                h[1] = h[1] &+ b
                h[2] = h[2] &+ c
                h[3] = h[3] &+ d
                h[4] = h[4] &+ e
                h[5] = h[5] &+ f
                h[6] = h[6] &+ g
                h[7] = h[7] &+ hh
            }
            return h.map { String(format: "%08x", $0) }.joined()
        }

        private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
            (x >> n) | (x << (32 - n))
        }
    }
#endif

/// Turns raw image sources into verified bytes. Pure and nonisolated.
enum AgentHandoffImageDecoder {
    /// Decodes base64 text. Checks the size before and after decoding and
    /// the magic bytes after.
    static func decode(
        base64 text: String,
        maximumBytes: Int = AgentHandoffImageLimits.maximumDecodedBytes
    ) -> AgentHandoffImageResult {
        // 4 base64 characters hold 3 bytes. Refuse early, before decoding.
        if text.utf8.count / 4 * 3 > maximumBytes + 3 { return .skipped(.tooLarge) }
        guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters),
            !data.isEmpty
        else { return .skipped(.badEncoding) }
        return verify(data, maximumBytes: maximumBytes)
    }

    /// Reads a regular file of at most `maximumBytes` and verifies it.
    static func decode(
        localFile path: String,
        maximumBytes: Int = AgentHandoffImageLimits.maximumDecodedBytes
    ) -> AgentHandoffImageResult {
        guard path.hasPrefix("/") else { return .skipped(.missingFile) }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        else { return .skipped(.missingFile) }
        guard values.isRegularFile == true else { return .skipped(.unreadable) }
        if let size = values.fileSize, size > maximumBytes { return .skipped(.tooLarge) }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .skipped(.unreadable)
        }
        return verify(data, maximumBytes: maximumBytes)
    }

    static func verify(_ data: Data, maximumBytes: Int) -> AgentHandoffImageResult {
        guard data.count <= maximumBytes else { return .skipped(.tooLarge) }
        guard let format = AgentHandoffImageFormat.detect(data) else {
            return .skipped(.unsupportedType)
        }
        return .image(
            AgentHandoffDecodedImage(
                data: data, format: format, sha256: AgentHandoffDigest.sha256Hex(data)))
    }

    static func decode(_ raw: AgentHandoffRawImage) -> AgentHandoffImageResult {
        switch raw {
        case .base64(let text): decode(base64: text)
        case .localFile(let path): decode(localFile: path)
        case .remote: .skipped(.remoteURL)
        case .unusable: .skipped(.badEncoding)
        }
    }
}

/// Finds image blocks in one parsed transcript line. The same function runs
/// at scan time (to count and place images) and at decode time (to read the
/// bytes), so the `ordinal` of an image is the same in both passes.
enum AgentHandoffImageExtractor {
    struct Found: Equatable {
        let raw: AgentHandoffRawImage
        let isToolResult: Bool
        /// The size of the base64 text, when the image is embedded.
        let encodedLength: Int?
    }

    // MARK: Claude Code

    /// `message.content[]` blocks of type `image` with
    /// `source: {type: "base64", media_type, data}`, and the same blocks
    /// inside a `tool_result` block's `content` list.
    static func claudeImages(_ entry: [String: Any]) -> [Found] {
        guard let message = AgentHistoryJSON.dictionary(entry["message"]),
            let blocks = AgentHistoryJSON.array(message["content"])
        else { return [] }
        var found: [Found] = []
        for case let block as [String: Any] in blocks {
            switch AgentHistoryJSON.string(block["type"]) {
            case "image":
                found.append(claudeImageBlock(block, isToolResult: false))
            case "tool_result":
                for case let inner as [String: Any] in AgentHistoryJSON.array(block["content"])
                    ?? []
                where AgentHistoryJSON.string(inner["type"]) == "image" {
                    found.append(claudeImageBlock(inner, isToolResult: true))
                }
            default:
                continue
            }
        }
        return found
    }

    private static func claudeImageBlock(_ block: [String: Any], isToolResult: Bool) -> Found {
        guard let source = AgentHistoryJSON.dictionary(block["source"]) else {
            return Found(raw: .unusable, isToolResult: isToolResult, encodedLength: nil)
        }
        switch AgentHistoryJSON.string(source["type"]) {
        case "base64":
            if let data = AgentHistoryJSON.string(source["data"]), !data.isEmpty {
                return Found(
                    raw: .base64(data), isToolResult: isToolResult, encodedLength: data.utf8.count)
            }
            return Found(raw: .unusable, isToolResult: isToolResult, encodedLength: nil)
        case "url":
            return Found(raw: .remote, isToolResult: isToolResult, encodedLength: nil)
        default:
            return Found(raw: .unusable, isToolResult: isToolResult, encodedLength: nil)
        }
    }

    // MARK: Codex

    /// A `response_item` payload: `message` content items of type
    /// `input_image` / `output_image` with `image_url`, and the same items in
    /// a tool call output.
    static func codexImages(_ payload: [String: Any]) -> [Found] {
        switch AgentHistoryJSON.string(payload["type"]) {
        case "message":
            return codexItems(AgentHistoryJSON.array(payload["content"]), isToolResult: false)
        case "function_call_output", "custom_tool_call_output":
            let output = payload["output"]
            if let items = output as? [Any] {
                return codexItems(items, isToolResult: true)
            }
            if let object = output as? [String: Any] {
                for key in ["content_items", "content"] {
                    if let items = AgentHistoryJSON.array(object[key]) {
                        return codexItems(items, isToolResult: true)
                    }
                }
            }
            return []
        default:
            return []
        }
    }

    private static func codexItems(_ items: [Any]?, isToolResult: Bool) -> [Found] {
        var found: [Found] = []
        for case let item as [String: Any] in items ?? [] {
            switch AgentHistoryJSON.string(item["type"]) {
            case "input_image", "output_image", "image":
                found.append(codexImageItem(item, isToolResult: isToolResult))
            default:
                continue
            }
        }
        return found
    }

    private static func codexImageItem(_ item: [String: Any], isToolResult: Bool) -> Found {
        var reference = AgentHistoryJSON.string(item["image_url"])
        if reference == nil, let object = AgentHistoryJSON.dictionary(item["image_url"]) {
            reference = AgentHistoryJSON.string(object["url"])
        }
        reference =
            reference ?? AgentHistoryJSON.string(item["url"])
            ?? AgentHistoryJSON.string(item["path"])
        guard let reference else {
            return Found(raw: .unusable, isToolResult: isToolResult, encodedLength: nil)
        }
        let raw = classify(reference: reference)
        var length: Int?
        if case .base64(let text) = raw { length = text.utf8.count }
        return Found(raw: raw, isToolResult: isToolResult, encodedLength: length)
    }

    /// `data:<media>;base64,<text>`, `file://…`, an absolute path, or a web
    /// address. Anything else is unusable.
    static func classify(reference: String) -> AgentHandoffRawImage {
        let text = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("data:") {
            guard let comma = text.firstIndex(of: ",") else { return .unusable }
            let header = text[text.startIndex..<comma].lowercased()
            guard header.hasSuffix(";base64") else { return .unusable }
            let payload = String(text[text.index(after: comma)...])
            return payload.isEmpty ? .unusable : .base64(payload)
        }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return .remote }
        if lower.hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL else { return .unusable }
            return .localFile(url.path)
        }
        if text.hasPrefix("/") { return .localFile(text) }
        return .unusable
    }
}
