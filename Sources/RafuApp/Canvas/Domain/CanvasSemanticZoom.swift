import Foundation

/// What a card shows at a board zoom level (review 7.6, node column).
nonisolated enum CanvasZoomFace: Equatable, Sendable {
    /// 75% and above: full live content.
    case full
    /// 50% to 75%: live content scaled down. A terminal does not resize its PTY.
    case scaledLive
    /// 25% to 50%: glyph, title, state, and one line.
    case summary
    /// Below 25%: a silhouette with the title only.
    case silhouette

    init(scale: Double) {
        if scale >= 0.75 {
            self = .full
        } else if scale >= 0.5 {
            self = .scaledLive
        } else if scale >= 0.25 {
            self = .summary
        } else {
            self = .silhouette
        }
    }

    /// Live native content (terminal, web, note editor, picture) is mounted.
    var showsLiveContent: Bool { self == .full || self == .scaledLive }
}

nonisolated enum CanvasZoomMetrics {
    static let minimumScale = 0.1
    static let maximumScale = 4.0
    static let minimumTitleScreenPoints = 11.0
    static let baseTitlePoints = 13.0

    static func clamped(_ scale: Double) -> Double {
        min(maximumScale, max(minimumScale, scale))
    }

    /// The logical title size that keeps the title at least 11 screen points.
    static func titleFontSize(scale: Double) -> Double {
        guard scale.isFinite, scale > 0 else { return baseTitlePoints }
        return max(baseTitlePoints, minimumTitleScreenPoints / scale)
    }
}

/// A soft detent at 100% while pinching. Within 3% either side the scale holds
/// at exactly 1, which is 6% of the travel.
nonisolated enum CanvasZoomDetent {
    static let halfWidth = 0.03

    static func apply(_ proposed: Double) -> Double {
        abs(proposed - 1) <= halfWidth ? 1 : proposed
    }

    static func isHolding(_ scale: Double) -> Bool { scale == 1 }

    /// True when the move from `previous` to `next` enters the detent or passes
    /// through it, so the haptic plays once per crossing.
    static func crossed(from previous: Double, to next: Double) -> Bool {
        let wasHolding = isHolding(apply(previous))
        let nowHolding = isHolding(apply(next))
        if nowHolding && !wasHolding { return true }
        return (previous < 1 - halfWidth && next > 1 + halfWidth)
            || (previous > 1 + halfWidth && next < 1 - halfWidth)
    }
}

/// Small text helpers for the summary face and the list. Pure and testable.
nonisolated enum CanvasCardSummaryText {
    /// "3/5" for a note with task items, or nil when it has none.
    static func taskCount(in text: String) -> String? {
        var total = 0
        var done = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
                let rest = trimmed.dropFirst(marker.count)
                if rest.hasPrefix("[ ] ") || rest == "[ ]" {
                    total += 1
                } else if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") || rest == "[x]"
                    || rest == "[X]"
                {
                    total += 1
                    done += 1
                }
            }
        }
        return total == 0 ? nil : "\(done)/\(total)"
    }

    /// The first non-empty line, with Markdown heading marks removed.
    static func firstLine(of text: String, limit: Int = 80) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let stripped = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            return String((stripped.isEmpty ? trimmed : stripped).prefix(limit))
        }
        return ""
    }

    /// The first `limit` lines of `text`, at most `byteLimit` UTF-8 bytes.
    static func excerpt(of text: String, lines limit: Int = 40, byteLimit: Int = 8 * 1_024)
        -> String
    {
        var result: [Substring] = []
        var bytes = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard result.count < limit else { break }
            bytes += line.utf8.count + 1
            guard bytes <= byteLimit else { break }
            result.append(line)
        }
        // A trailing newline produces one empty element; drop it.
        if result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }

    /// "5 cards · edited 2 h ago" for the Open Canvas sheet.
    static func libraryDetail(cardCount: Int, modified: Date?, now: Date = Date()) -> String {
        let cards = cardCount == 1 ? "1 card" : "\(cardCount) cards"
        guard let modified else { return cards }
        let seconds = max(0, now.timeIntervalSince(modified))
        let age: String
        switch seconds {
        case ..<60: age = "just now"
        case ..<3_600: age = "\(Int(seconds / 60)) min ago"
        case ..<86_400: age = "\(Int(seconds / 3_600)) h ago"
        default: age = "\(Int(seconds / 86_400)) d ago"
        }
        return "\(cards) · edited \(age)"
    }
}
