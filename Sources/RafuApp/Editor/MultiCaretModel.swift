import Foundation

/// Pure UTF-16 edit math for Rafu's view-owned multi-caret state.
///
/// Ranges are always clamped, sorted, and disjoint. Overlapping or adjacent
/// selections coalesce, duplicate empty carets are dropped, and
/// `primaryIndex` follows the input primary through those transformations.
nonisolated struct MultiCaretModel: Equatable, Sendable {
    static let occurrenceLimit = 1_000

    let ranges: [NSRange]
    let primaryIndex: Int

    var primaryRange: NSRange { ranges[primaryIndex] }

    init(ranges: [NSRange], primaryIndex: Int = 0, textLength: Int) {
        let result = Self.normalize(
            ranges: ranges,
            primaryIndex: primaryIndex,
            textLength: textLength
        )
        self.ranges = result.ranges
        self.primaryIndex = result.primaryIndex
    }

    func normalized(textLength: Int) -> MultiCaretModel {
        MultiCaretModel(ranges: ranges, primaryIndex: primaryIndex, textLength: textLength)
    }

    /// Produces edits from the end of the buffer toward the beginning, then
    /// computes the collapsed carets in the final text coordinate space.
    func applyingReplacement(_ replacement: String, at textLength: Int) -> MultiCaretEditResult {
        let source = normalized(textLength: textLength)
        let replacementLength = (replacement as NSString).length
        let edits = source.ranges.reversed().map {
            MultiCaretSubedit(range: $0, replacement: replacement)
        }

        var cumulativeShift = 0
        var newRanges: [NSRange] = []
        newRanges.reserveCapacity(source.ranges.count)
        for range in source.ranges {
            newRanges.append(
                NSRange(
                    location: range.location + cumulativeShift + replacementLength,
                    length: 0
                )
            )
            cumulativeShift += replacementLength - range.length
        }

        let newTextLength = max(0, max(textLength, 0) + cumulativeShift)
        return MultiCaretEditResult(
            edits: edits,
            model: MultiCaretModel(
                ranges: newRanges,
                primaryIndex: source.primaryIndex,
                textLength: newTextLength
            )
        )
    }

    /// Expands empty carets to composed-character deletion targets before
    /// applying an empty replacement. This keeps UTF-16 surrogate pairs and
    /// other extended grapheme clusters intact.
    func applyingDeletion(
        _ direction: MultiCaretDeletionDirection,
        in text: String
    ) -> MultiCaretEditResult {
        let content = text as NSString
        let source = normalized(textLength: content.length)
        let targets = source.ranges.map { range in
            guard range.length == 0 else { return range }
            switch direction {
            case .backward:
                guard range.location > 0 else { return range }
                return content.rangeOfComposedCharacterSequence(at: range.location - 1)
            case .forward:
                guard range.location < content.length else { return range }
                return content.rangeOfComposedCharacterSequence(at: range.location)
            }
        }
        let targetModel = MultiCaretModel(
            ranges: targets,
            primaryIndex: source.primaryIndex,
            textLength: content.length
        )
        let result = targetModel.applyingReplacement("", at: content.length)
        return MultiCaretEditResult(
            edits: result.edits.filter { $0.range.length > 0 },
            model: result.model
        )
    }

    /// Implements select-next semantics. The first invocation at an empty
    /// caret selects the identifier under that caret; subsequent invocations
    /// append the next literal substring match, wrapping once at EOF.
    func selectingNextOccurrence(
        in text: String,
        limit: Int = MultiCaretModel.occurrenceLimit
    ) -> MultiCaretModel {
        guard let seed = occurrenceSeed(in: text) else {
            return normalized(textLength: (text as NSString).length)
        }
        if seed.expandedEmptySelection { return seed.model }

        let matches = Self.literalOccurrences(
            of: seed.needle,
            in: text,
            limit: limit
        )
        let selected = Set(seed.model.ranges)
        let searchStart = seed.model.ranges.map(NSMaxRange).max() ?? 0
        let next =
            matches.first { $0.location >= searchStart && !selected.contains($0) }
            ?? matches.first { !selected.contains($0) }
        guard let next else { return seed.model }
        return seed.model.addingCaret(range: next, textLength: (text as NSString).length)
    }

    /// Selects every non-overlapping literal substring match of the primary
    /// selection, capped to keep huge buffers bounded.
    func selectingAllOccurrences(
        in text: String,
        limit: Int = MultiCaretModel.occurrenceLimit
    ) -> MultiCaretModel {
        guard let seed = occurrenceSeed(in: text) else {
            return normalized(textLength: (text as NSString).length)
        }
        let matches = Self.literalOccurrences(
            of: seed.needle,
            in: text,
            limit: limit
        )
        guard !matches.isEmpty else { return seed.model }
        let primaryIndex = matches.firstIndex(of: seed.model.primaryRange) ?? 0
        return MultiCaretModel(
            ranges: matches,
            primaryIndex: primaryIndex,
            textLength: (text as NSString).length
        )
    }

    func addingCaret(at location: Int, textLength: Int) -> MultiCaretModel {
        addingCaret(
            range: NSRange(location: location, length: 0),
            textLength: textLength
        )
    }

    func togglingCaret(at location: Int, textLength: Int) -> MultiCaretModel {
        let source = normalized(textLength: textLength)
        let clampedLocation = min(max(location, 0), max(textLength, 0))
        if source.ranges.count > 1,
            let index = source.ranges.firstIndex(of: NSRange(location: clampedLocation, length: 0))
        {
            var newRanges = source.ranges
            newRanges.remove(at: index)
            let adjustedPrimary: Int
            if index < source.primaryIndex {
                adjustedPrimary = source.primaryIndex - 1
            } else if index == source.primaryIndex {
                adjustedPrimary = min(index, newRanges.count - 1)
            } else {
                adjustedPrimary = source.primaryIndex
            }
            return MultiCaretModel(
                ranges: newRanges,
                primaryIndex: adjustedPrimary,
                textLength: textLength
            )
        }
        return source.addingCaret(at: clampedLocation, textLength: textLength)
    }

    func collapsedToPrimary(textLength: Int) -> MultiCaretModel {
        let source = normalized(textLength: textLength)
        return MultiCaretModel(ranges: [source.primaryRange], textLength: textLength)
    }

    /// Maps a remembered visual column onto a target line. `lineLength`
    /// excludes its newline terminator; ragged and empty lines clamp safely.
    static func caretLocation(
        lineStartOffset: Int,
        lineLength: Int,
        goalColumn: Int
    ) -> Int {
        max(lineStartOffset, 0) + min(max(goalColumn, 0), max(lineLength, 0))
    }

    private func addingCaret(range: NSRange, textLength: Int) -> MultiCaretModel {
        let source = normalized(textLength: textLength)
        return MultiCaretModel(
            ranges: source.ranges + [range],
            primaryIndex: source.primaryIndex,
            textLength: textLength
        )
    }

    private func occurrenceSeed(in text: String) -> OccurrenceSeed? {
        let content = text as NSString
        let source = normalized(textLength: content.length)
        if source.primaryRange.length > 0 {
            let needle = content.substring(with: source.primaryRange)
            guard !needle.isEmpty else { return nil }
            return OccurrenceSeed(model: source, needle: needle, expandedEmptySelection: false)
        }
        guard
            let identifier = IdentifierUnderCaret.word(
                in: text,
                at: source.primaryRange.location
            )
        else { return nil }
        let identifierRange = NSRange(
            location: identifier.position,
            length: (identifier.word as NSString).length
        )
        var expandedRanges = source.ranges
        expandedRanges[source.primaryIndex] = identifierRange
        let expanded = MultiCaretModel(
            ranges: expandedRanges,
            primaryIndex: source.primaryIndex,
            textLength: content.length
        )
        return OccurrenceSeed(
            model: expanded,
            needle: identifier.word,
            expandedEmptySelection: true
        )
    }

    private static func literalOccurrences(
        of needle: String,
        in text: String,
        limit: Int
    ) -> [NSRange] {
        let content = text as NSString
        let boundedLimit = min(max(limit, 0), occurrenceLimit)
        let needleLength = (needle as NSString).length
        guard boundedLimit > 0, needleLength > 0, needleLength <= content.length else { return [] }

        var matches: [NSRange] = []
        matches.reserveCapacity(min(boundedLimit, 32))
        var searchLocation = 0
        while searchLocation <= content.length - needleLength, matches.count < boundedLimit {
            let searchRange = NSRange(
                location: searchLocation,
                length: content.length - searchLocation
            )
            let match = content.range(of: needle, options: [], range: searchRange)
            guard match.location != NSNotFound else { break }
            matches.append(match)
            searchLocation = NSMaxRange(match)
        }
        return matches
    }

    private static func normalize(
        ranges: [NSRange],
        primaryIndex: Int,
        textLength: Int
    ) -> (ranges: [NSRange], primaryIndex: Int) {
        let safeTextLength = max(textLength, 0)
        let safePrimaryIndex = ranges.indices.contains(primaryIndex) ? primaryIndex : 0
        var entries = ranges.enumerated().map { index, range in
            let location = min(max(range.location, 0), safeTextLength)
            let length = min(max(range.length, 0), safeTextLength - location)
            return RangeEntry(
                range: NSRange(location: location, length: length),
                containsPrimary: index == safePrimaryIndex
            )
        }
        if entries.isEmpty {
            entries = [
                RangeEntry(
                    range: NSRange(location: 0, length: 0),
                    containsPrimary: true
                )
            ]
        }
        entries.sort {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            return $0.range.length > $1.range.length
        }

        var merged: [RangeEntry] = []
        merged.reserveCapacity(entries.count)
        for entry in entries {
            guard var last = merged.last else {
                merged.append(entry)
                continue
            }
            let lastEnd = NSMaxRange(last.range)
            if entry.range.location <= lastEnd {
                let end = max(lastEnd, NSMaxRange(entry.range))
                last.range.length = end - last.range.location
                last.containsPrimary = last.containsPrimary || entry.containsPrimary
                merged[merged.count - 1] = last
            } else {
                merged.append(entry)
            }
        }

        let normalizedPrimaryIndex = merged.firstIndex { $0.containsPrimary } ?? 0
        return (merged.map(\.range), normalizedPrimaryIndex)
    }
}

nonisolated struct MultiCaretSubedit: Equatable, Sendable {
    let range: NSRange
    let replacement: String
}

nonisolated struct MultiCaretEditResult: Equatable, Sendable {
    let edits: [MultiCaretSubedit]
    let model: MultiCaretModel
}

nonisolated enum MultiCaretDeletionDirection: Sendable {
    case backward
    case forward
}

private nonisolated struct RangeEntry {
    var range: NSRange
    var containsPrimary: Bool
}

private nonisolated struct OccurrenceSeed {
    let model: MultiCaretModel
    let needle: String
    let expandedEmptySelection: Bool
}
