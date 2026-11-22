import Foundation

/// Splits text into search tokens: lowercase letters and digits, with
/// diacritics folded away (`José` gives `jose`).
enum MeetingSearchTokenizer {
    static let maximumTokenLength = 40
    static let maximumQueryTokens = 8

    static func tokens(in text: String) -> [String] {
        var source = text
        if !text.utf8.allSatisfy({ $0 < 0x80 }) {
            source = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        }
        var result: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty {
                result.append(String(current))
                current.removeAll(keepingCapacity: true)
            }
        }
        for scalar in source.unicodeScalars {
            if scalar.isASCII {
                let value = scalar.value
                if value >= 0x61 && value <= 0x7A || value >= 0x30 && value <= 0x39 {
                    current.append(scalar)
                } else if value >= 0x41 && value <= 0x5A {
                    current.append(Unicode.Scalar(value + 32) ?? scalar)
                } else {
                    flush()
                }
            } else if CharacterSet.alphanumerics.contains(scalar) {
                current.append(contentsOf: String(scalar).lowercased().unicodeScalars)
            } else {
                flush()
            }
            if current.count >= maximumTokenLength { flush() }
        }
        flush()
        return result
    }
}

/// An in-memory inverted index over meeting titles and turn text. It holds
/// token → (meeting, turn) rows and no transcript text, so its memory grows
/// with the number of distinct words. It is made from the files, kept up to
/// date by the store, and can always be made again.
struct MeetingSearchIndex {
    struct Posting: Hashable {
        let meeting: MeetingID
        /// The turn number, or -1 for a hit in the meeting title.
        let turn: Int
    }

    private var postings: [String: Set<Posting>] = [:]
    private var tokensByMeeting: [MeetingID: Set<String>] = [:]
    private var dates: [MeetingID: Date] = [:]

    var meetingCount: Int { dates.count }

    /// Replaces every row of one meeting.
    mutating func replace(
        meeting: MeetingID, title: String, startDate: Date,
        turns: [(id: MeetingTurnID, text: String)]
    ) {
        remove(meeting: meeting)
        dates[meeting] = startDate
        var tokenSet = Set<String>()
        func add(_ text: String, turn: Int) {
            let posting = Posting(meeting: meeting, turn: turn)
            for token in MeetingSearchTokenizer.tokens(in: text) {
                postings[token, default: []].insert(posting)
                tokenSet.insert(token)
            }
        }
        add(title, turn: -1)
        for turn in turns { add(turn.text, turn: turn.id.number) }
        tokensByMeeting[meeting] = tokenSet
    }

    /// Adds turns to a meeting that is already in the index.
    mutating func append(
        meeting: MeetingID, turns: [(id: MeetingTurnID, text: String)]
    ) {
        guard dates[meeting] != nil else { return }
        var tokenSet = tokensByMeeting[meeting] ?? []
        for turn in turns {
            let posting = Posting(meeting: meeting, turn: turn.id.number)
            for token in MeetingSearchTokenizer.tokens(in: turn.text) {
                postings[token, default: []].insert(posting)
                tokenSet.insert(token)
            }
        }
        tokensByMeeting[meeting] = tokenSet
    }

    mutating func remove(meeting: MeetingID) {
        if let tokens = tokensByMeeting.removeValue(forKey: meeting) {
            for token in tokens {
                guard var set = postings[token] else { continue }
                set = set.filter { $0.meeting != meeting }
                postings[token] = set.isEmpty ? nil : set
            }
        }
        dates[meeting] = nil
    }

    func contains(meeting: MeetingID) -> Bool { dates[meeting] != nil }

    /// Rows where every query word starts a word of the title or of one
    /// turn. Newest meeting first, the title row before the turn rows, then
    /// turns in order.
    func search(_ query: String, limit: Int) -> [Posting] {
        guard limit > 0 else { return [] }
        let queryTokens = Array(
            MeetingSearchTokenizer.tokens(in: query).prefix(
                MeetingSearchTokenizer.maximumQueryTokens)
        )
        guard !queryTokens.isEmpty else { return [] }
        var matches: [Set<Posting>] = []
        for token in queryTokens {
            var union = Set<Posting>()
            if let exact = postings[token] { union.formUnion(exact) }
            for (key, set) in postings where key != token && key.hasPrefix(token) {
                union.formUnion(set)
            }
            if union.isEmpty { return [] }
            matches.append(union)
        }
        matches.sort { $0.count < $1.count }
        var result = matches[0]
        for other in matches.dropFirst() {
            result = result.filter { other.contains($0) }
            if result.isEmpty { return [] }
        }
        let ordered = result.sorted { lhs, rhs in
            let leftDate = dates[lhs.meeting] ?? .distantPast
            let rightDate = dates[rhs.meeting] ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            if lhs.meeting != rhs.meeting { return lhs.meeting.uuidString < rhs.meeting.uuidString }
            return lhs.turn < rhs.turn
        }
        return Array(ordered.prefix(limit))
    }
}
