import Foundation
import Testing

@testable import RafuApp

@Suite("Inline blame formatter")
struct InlineBlameFormatterTests {
    private static let reference = Date(timeIntervalSince1970: 1_000_000)

    private func line(
        author: String = "Ada Lovelace",
        summary: String = "Fix the loop",
        secondsAgo: TimeInterval = 0
    ) -> GitBlameLine {
        GitBlameLine(
            lineNumber: 1,
            commitID: String(repeating: "a", count: 40),
            shortID: "aaaaaaaa",
            author: author,
            time: Self.reference.addingTimeInterval(-secondsAgo),
            summary: summary,
            isBoundary: false
        )
    }

    @Test("Formats author, relative time, and summary")
    func formatsFields() {
        let text = InlineBlameFormatter.format(
            line(secondsAgo: 3_600), referenceDate: Self.reference)
        #expect(text == "Ada Lovelace • 1h ago • Fix the loop")
    }

    @Test("Relative time buckets: just now, minutes, hours, days, weeks, months, years")
    func relativeTimeBuckets() {
        #expect(
            InlineBlameFormatter.relativeTime(from: Self.reference, to: Self.reference)
                == "just now")
        #expect(
            InlineBlameFormatter.relativeTime(
                from: Self.reference.addingTimeInterval(-59), to: Self.reference) == "just now")
        #expect(
            InlineBlameFormatter.relativeTime(
                from: Self.reference.addingTimeInterval(-300), to: Self.reference) == "5m ago")
        #expect(
            InlineBlameFormatter.relativeTime(
                from: Self.reference.addingTimeInterval(-7_200), to: Self.reference) == "2h ago")
        #expect(
            InlineBlameFormatter.relativeTime(
                from: Self.reference.addingTimeInterval(-172_800), to: Self.reference) == "2d ago")
        #expect(
            InlineBlameFormatter.relativeTime(
                from: Self.reference.addingTimeInterval(-1_209_600), to: Self.reference) == "2w ago"
        )
        #expect(
            InlineBlameFormatter.relativeTime(
                from: Self.reference.addingTimeInterval(-5_259_600), to: Self.reference)
                == "2mo ago")
        #expect(
            InlineBlameFormatter.relativeTime(
                from: Self.reference.addingTimeInterval(-63_115_200), to: Self.reference)
                == "2y ago")
    }

    @Test("Relative time is deterministic against the injected reference date, not the live clock")
    func deterministicAgainstInjectedDate() {
        let farFuture = Date(timeIntervalSince1970: 9_999_999_999)
        #expect(
            InlineBlameFormatter.relativeTime(from: Self.reference, to: farFuture) != "just now")
        // A "future" line relative to its own reference clamps rather than
        // going negative.
        #expect(
            InlineBlameFormatter.relativeTime(
                from: Self.reference.addingTimeInterval(10), to: Self.reference) == "just now")
    }

    @Test("Text shorter than the budget is returned unchanged")
    func noTruncationWhenShort() {
        let text = InlineBlameFormatter.middleTruncated("short text", characterBudget: 80)
        #expect(text == "short text")
    }

    @Test("Middle truncation keeps head and tail with a single ellipsis")
    func middleTruncation() {
        let long = String(repeating: "x", count: 50) + "MIDDLE" + String(repeating: "y", count: 50)
        let truncated = InlineBlameFormatter.middleTruncated(long, characterBudget: 20)
        #expect(truncated.count == 20)
        #expect(truncated.contains("…"))
        #expect(truncated.hasPrefix("x"))
        #expect(truncated.hasSuffix("y"))
    }

    @Test("Formatted ghost text for a long summary stays within the default budget")
    func formattedTextRespectsDefaultBudget() {
        let summary = String(repeating: "a very long commit summary ", count: 10)
        let text = InlineBlameFormatter.format(
            line(summary: summary, secondsAgo: 60), referenceDate: Self.reference)
        #expect(text.count <= InlineBlameFormatter.defaultCharacterBudget)
        #expect(text.contains("…"))
    }

    @Test("A tiny budget still returns a bounded, non-crashing result")
    func tinyBudget() {
        let text = InlineBlameFormatter.middleTruncated("some text here", characterBudget: 1)
        #expect(text.count == 1)
    }
}
