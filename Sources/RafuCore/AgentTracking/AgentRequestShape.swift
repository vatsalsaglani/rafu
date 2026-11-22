import Foundation
import Synchronization
import os

/// The shape of an agent request that Rafu could not fully show: the method
/// or tool name, the key names of the first two levels, and the JSON type of
/// each value. Never a value. One line of it goes to the unified log, so the
/// next unknown prompt is found by Rafu, not by the user.
///
/// Read it with:
/// `log show --last 1h --predicate 'category == "AgentRequestShape"' --info`
///
/// Rules that keep values out:
///
/// - A string, number or bool shows only as its type (`string`, `number`,
///   `bool`); an array as `array[n]`; `null` as `null`.
/// - A key name shows only when the caller says the names are fixed by the
///   agent's own code (`KeyNames.recorded`: a Claude Code built-in tool, a
///   Codex `params` object). Else only the count of keys per type shows
///   (`KeyNames.counted`: the input of an MCP tool, whose server picks the
///   names).
/// - A recorded key name outside `[A-Za-z0-9_.-]`, or longer than 64 bytes,
///   shows as `?`.
/// - The value of a key named `properties` (a schema a server chose) shows
///   only as `object[n]`.
public nonisolated enum AgentRequestShape {
    /// Whether key names may be shown.
    public enum KeyNames: Sendable {
        /// The agent's own code fixes the names: show them.
        case recorded
        /// Someone else (an MCP server) picks the names: show counts only.
        case counted
    }

    /// The longest shape line, in UTF-8 bytes. Longer is cut and ends in `…`.
    public static let maximumBytes = 512
    /// The longest key name shown.
    public static let maximumKeyNameBytes = 64
    /// The logger category.
    public static let category = "AgentRequestShape"

    /// One line that describes `value` under `name`. `name` is shown only
    /// when it is a safe name (see `safeName(_:)`); else as `?`.
    public static func describe(name: String, value: Any?, keyNames: KeyNames) -> String {
        let line = safeName(name) + " " + describe(value, level: 1, keyNames: keyNames)
        return bounded(line)
    }

    /// `name` when it has only `[A-Za-z0-9_./-]` and at most 200 bytes, else
    /// `?`. Tool names and Codex method names pass; free text does not.
    public static func safeName(_ name: String) -> String {
        guard !name.isEmpty, name.utf8.count <= AgentPermissionRequestSummary.maximumToolNameBytes,
            name.utf8.allSatisfy({ isNameByte($0) || $0 == UInt8(ascii: "/") })
        else { return "?" }
        return name
    }

    /// A shape line from an untrusted source (a spool file), reduced to the
    /// characters `describe` writes and to `maximumBytes`. Nil when empty.
    public static func sanitized(_ line: String) -> String? {
        let allowed = line.unicodeScalars.filter { scalar in
            scalar.isASCII
                && (isNameByte(UInt8(scalar.value))
                    || " /?:,{}[]".unicodeScalars.contains(scalar))
        }
        let text = bounded(String(String.UnicodeScalarView(allowed)))
        return text.isEmpty ? nil : text
    }

    private static func describe(_ value: Any?, level: Int, keyNames: KeyNames) -> String {
        switch value {
        case nil, is NSNull: return "null"
        case let number as NSNumber:
            // JSONSerialization gives NSNumber for bool and number alike.
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
        case is String: return "string"
        case let array as [Any]: return "array[\(array.count)]"
        case let object as [String: Any]:
            guard level <= 2 else { return "object" }
            switch keyNames {
            case .counted:
                var counts: [String: Int] = [:]
                for item in object.values {
                    counts[describe(item, level: 3, keyNames: .counted).typeWord, default: 0] += 1
                }
                let parts = counts.keys.sorted().map { "\($0):\(counts[$0] ?? 0)" }
                return "object[\(object.count)]{" + parts.joined(separator: ",") + "}"
            case .recorded:
                let parts = object.keys.sorted().map { key -> String in
                    let item = object[key]
                    let shape =
                        key == "properties"
                        ? "object[\((item as? [String: Any])?.count ?? 0)]"
                        : describe(item, level: level + 1, keyNames: .recorded)
                    return safeKey(key) + ":" + shape
                }
                return "{" + parts.joined(separator: ",") + "}"
            }
        default: return "?"
        }
    }

    private static func safeKey(_ key: String) -> String {
        guard !key.isEmpty, key.utf8.count <= maximumKeyNameBytes,
            key.utf8.allSatisfy({ isNameByte($0) })
        else { return "?" }
        return key
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"),
            UInt8(ascii: "."):
            true
        default: false
        }
    }

    private static func bounded(_ line: String) -> String {
        guard line.utf8.count > maximumBytes else { return line }
        var result = ""
        var used = 0
        let limit = maximumBytes - "…".utf8.count
        for character in line {
            let size = character.utf8.count
            guard used + size <= limit else { break }
            result.append(character)
            used += size
        }
        return result + "…"
    }

    // MARK: Recording

    /// Logs each distinct shape once per process, at most `maximumShapes`
    /// shapes. Thread-safe.
    public final class Recorder: Sendable {
        /// The most distinct shapes logged per process.
        public static let maximumShapes = 64
        /// The recorder of this process.
        public static let shared = Recorder()

        private let seen = Mutex<Set<String>>([])
        private let logger: Logger

        public init(subsystem: String = Bundle.main.bundleIdentifier ?? "rafu") {
            logger = Logger(subsystem: subsystem, category: AgentRequestShape.category)
        }

        /// Logs `shape` (sanitized again) unless it was logged before or the
        /// set is full. Returns true when it logged.
        @discardableResult
        public func record(_ shape: String) -> Bool {
            guard let line = AgentRequestShape.sanitized(shape) else { return false }
            let isNew = seen.withLock { seen in
                guard seen.count < Self.maximumShapes, !seen.contains(line) else { return false }
                seen.insert(line)
                return true
            }
            guard isNew else { return false }
            // A shape holds names and types only, never a value.
            logger.notice("Unknown agent request shape: \(line, privacy: .public)")
            return true
        }
    }
}

extension String {
    /// The type word of a shape part: `object[2]{...}` gives `object`.
    fileprivate var typeWord: String {
        String(prefix { $0 != "[" && $0 != "{" })
    }
}
