import Foundation

/// Bounds and redacts terminal viewport lines before they reach the voice
/// backend. Over-redaction is accepted: a long path or hash becomes
/// `[redacted]` too.
public nonisolated enum VoiceOutputScrubber {
    public static let redaction = "[redacted]"

    /// Multi-line secrets, matched across the joined text first.
    private static let blockPatterns = [
        #"-----BEGIN[^-]*PRIVATE KEY-----[\s\S]*?(-----END[^-]*PRIVATE KEY-----|$)"#
    ]

    /// Single-line secrets. Order matters: the specific token shapes run
    /// before the generic long-token rule.
    private static let linePatterns = [
        #"sk-[A-Za-z0-9_-]{8,}"#,
        #"github_pat_[A-Za-z0-9_]+"#,
        #"gh[op]_[A-Za-z0-9_]+"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"xox[baprs]-[A-Za-z0-9-]*"#,
        #"Bearer\s+\S+"#,
        #"(?i)(password|passwd|token|secret|api[_-]?key)\s*[=:]\s*\S+"#,
        #"[A-Za-z0-9+/=_-]{40,}"#,
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    private static func redact(_ text: String, patterns: [String]) -> String {
        var value = text
        for pattern in patterns {
            guard let expression = regex(pattern) else { continue }
            value = expression.stringByReplacingMatches(
                in: value, range: NSRange(value.startIndex..., in: value),
                withTemplate: redaction)
        }
        return value
    }

    /// The last `maxLines` non-empty lines, each at most `maxLineBytes`, the
    /// whole at most `maxBytes`, with secrets replaced and control
    /// characters turned into spaces.
    public static func scrub(
        lines: [String], maxLines: Int = 40, maxLineBytes: Int = 200, maxBytes: Int = 4_096
    ) -> String {
        let joined = redact(lines.joined(separator: "\n"), patterns: blockPatterns)
        var kept: [String] = []
        for line in joined.split(separator: "\n", omittingEmptySubsequences: false) {
            let redacted = redact(String(line), patterns: linePatterns)
            let single = CanvasAgentText.singleLine(redacted, maxBytes: maxLineBytes)
                .trimmingCharacters(in: .whitespaces)
            if !single.isEmpty { kept.append(single) }
        }
        kept = Array(kept.suffix(max(0, maxLines)))
        while !kept.isEmpty, kept.joined(separator: "\n").utf8.count > maxBytes {
            kept.removeFirst()
        }
        return kept.joined(separator: "\n")
    }
}
