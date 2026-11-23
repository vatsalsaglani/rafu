import Darwin
import Foundation

/// The meeting library: plain files in Rafu's app data.
///
/// Layout, for each meeting, below the injected root (default
/// `<applicationSupportRoot>/Meetings/Library`):
///
///     <MEETING-UUID>/                 folder, mode 0700
///         meeting.json                the record; atomic writes; has a version counter
///         turns.jsonl                 one turn for each line; append only while processing
///         edits.jsonl                 speaker renames and text edits (never rewrites turns)
///         conversation.jsonl          questions and answers with citations
///         notes.json                  the title and summary that the agent wrote
///         audio/                      folder, mode 0700: me.caf, them.caf, journal files
///
/// Files have mode 0600. The actor is the only writer, and each write of
/// `meeting.json` checks the version that the caller read. A meeting is never
/// workspace data: no method takes or returns a workspace path.
public actor MeetingStore: MeetingNotesStoring {
    // MARK: Limits

    static let recordFileLimit = 256 * 1024
    static let turnsFileLimit = 32 * 1024 * 1024
    static let editsFileLimit = 8 * 1024 * 1024
    static let conversationFileLimit = 16 * 1024 * 1024
    static let notesFileLimit = 256 * 1024
    static let maximumTitleCharacters = 200
    static let maximumNameCharacters = 80
    static let untitled = "Untitled meeting"

    // MARK: Roots

    /// `<applicationSupportRoot>/Meetings/Library`. The only place that turns
    /// an app identity into the library root; Rafu and Rafu Lightning keep
    /// separate roots because `applicationSupportRoot` does.
    public static func defaultRootDirectory(
        identity: RafuAppIdentity = .current,
        baseDirectory: URL = RafuAppIdentity.defaultApplicationSupportBaseDirectory
    ) -> URL {
        identity.applicationSupportRoot(baseDirectory: baseDirectory)
            .appending(path: "Meetings", directoryHint: .isDirectory)
            .appending(path: "Library", directoryHint: .isDirectory)
    }

    private let root: URL
    private let diagnosticsDirectory: URL
    private let snapshotRoot: URL
    private let diagnostics: any MeetingDiagnosticsRecording
    private let clock: @Sendable () -> Date
    private var index: MeetingSearchIndex?

    /// Making a store touches no file. The folders are made at the first
    /// write.
    ///
    /// - Parameters:
    ///   - rootDirectory: the library root. There is no default on purpose:
    ///     a test must pass a temporary root.
    ///   - diagnosticsDirectory: where the diagnostics package keeps one
    ///     file for each meeting (`<id>.jsonl`, `<id>.1.jsonl`). Default: the
    ///     `Diagnostics` folder next to the library root.
    ///   - snapshotRoot: the private temporary root of agent snapshots.
    public init(
        rootDirectory: URL,
        diagnosticsDirectory: URL? = nil,
        snapshotRoot: URL? = nil,
        diagnostics: any MeetingDiagnosticsRecording = NoopMeetingDiagnostics(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = rootDirectory
        self.diagnosticsDirectory =
            diagnosticsDirectory
            ?? rootDirectory.deletingLastPathComponent()
            .appending(path: "Diagnostics", directoryHint: .isDirectory)
        self.snapshotRoot =
            snapshotRoot
            ?? FileManager.default.temporaryDirectory
            .appending(path: "MeetingAgentSnapshots", directoryHint: .isDirectory)
        self.diagnostics = diagnostics
        self.clock = clock
    }

    // MARK: Create and list

    public func create(title: String, startDate: Date) async throws -> MeetingSummaryRecord {
        try reporting(nil, reportSuccess: true) {
            try MeetingFileIO.ensurePrivateDirectory(root)
            let id = MeetingID()
            let folder = folderURL(id)
            do {
                try MeetingFileIO.ensurePrivateDirectory(folder)
                try MeetingFileIO.ensurePrivateDirectory(audioURL(id))
                let record = MeetingRecordFile(
                    version: 1, id: id, title: Self.cleanTitle(title), startDate: startDate,
                    duration: 0, state: .recording, engines: MeetingEngineUse())
                try writeRecord(record)
                index?.replace(
                    meeting: id, title: record.title, startDate: startDate, turns: [])
                return summary(from: record)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
    }

    public func list() async throws -> [MeetingSummaryRecord] {
        var result: [MeetingSummaryRecord] = []
        for id in meetingIDs() {
            if let record = try? loadRecord(id) { result.append(summary(from: record)) }
        }
        return result.sorted {
            if $0.startDate != $1.startDate { return $0.startDate > $1.startDate }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func summary(of meeting: MeetingID) async throws -> MeetingSummaryRecord? {
        do {
            return summary(from: try loadRecord(meeting))
        } catch MeetingStoreError.notFound {
            return nil
        }
    }

    // MARK: Turns

    @discardableResult
    public func appendTurns(
        _ turns: [MeetingTurn], to meeting: MeetingID, expectedVersion: Int
    ) async throws -> Int {
        try reporting(meeting, reportSuccess: false) {
            var record = try loadRecord(meeting)
            try check(record, expected: expectedVersion)
            guard !turns.isEmpty else { return record.version }
            let payload = try Self.encodeLines(turns) { MeetingStoreError.turnTooLarge($0.id) }
            try MeetingFileIO.append(payload, to: fileURL(meeting, "turns.jsonl"))
            let latestEnd = turns.map(\.end).filter(\.isFinite).max() ?? 0
            record.duration = max(record.duration, latestEnd)
            record.version += 1
            try writeRecord(record)
            index?.append(meeting: meeting, turns: turns.map { ($0.id, $0.text) })
            return record.version
        }
    }

    public func turns(
        of meeting: MeetingID, after: MeetingTurnID?, limit: Int
    ) async throws -> MeetingTurnPage {
        let record = try loadRecord(meeting)
        let all = try effectiveTurns(meeting).turns
        var start = 0
        if let after {
            if let position = all.firstIndex(where: { $0.id == after }) {
                start = position + 1
            } else {
                start = all.firstIndex(where: { $0.id > after }) ?? all.count
            }
        }
        let size = max(1, min(limit, 5_000))
        let end = min(all.count, start + size)
        let page = Array(all[start..<end])
        let next: MeetingTurnID? = end < all.count ? page.last?.id : nil
        return MeetingTurnPage(turns: page, nextAfter: next, version: record.version)
    }

    // MARK: Changes

    @discardableResult
    public func setState(
        _ state: MeetingState, of meeting: MeetingID, expectedVersion: Int
    ) async throws -> Int {
        try reporting(meeting, reportSuccess: true) {
            try mutate(meeting, expectedVersion: expectedVersion) { $0.state = state }.version
        }
    }

    @discardableResult
    public func rename(
        _ meeting: MeetingID, title: String, expectedVersion: Int
    ) async throws -> Int {
        try reporting(meeting, reportSuccess: true) {
            let record = try mutate(meeting, expectedVersion: expectedVersion) {
                $0.title = Self.cleanTitle(title)
                $0.titleOrigin = MeetingRecordFile.userTitle
            }
            try reindex(meeting)
            return record.version
        }
    }

    @discardableResult
    public func renameSpeaker(
        _ label: MeetingSpeakerLabel, to name: String, in meeting: MeetingID,
        expectedVersion: Int
    ) async throws -> Int {
        try reporting(meeting, reportSuccess: true) {
            try mutate(meeting, expectedVersion: expectedVersion) { _ in
                let line = MeetingEditLine(
                    kind: .speakerName, date: clock(), speaker: label,
                    name: Self.cleanName(name), turn: nil, text: nil)
                try appendEdit(line, to: meeting)
            }.version
        }
    }

    @discardableResult
    public func setDuration(
        _ seconds: TimeInterval, of meeting: MeetingID, expectedVersion: Int
    ) async throws -> Int {
        try reporting(meeting, reportSuccess: true) {
            try mutate(meeting, expectedVersion: expectedVersion) {
                $0.duration = seconds.isFinite ? max(0, seconds) : 0
            }.version
        }
    }

    @discardableResult
    public func setEngines(
        _ engines: MeetingEngineUse, of meeting: MeetingID, expectedVersion: Int
    ) async throws -> Int {
        try reporting(meeting, reportSuccess: true) {
            try mutate(meeting, expectedVersion: expectedVersion) { $0.engines = engines }.version
        }
    }

    @discardableResult
    public func replaceTurns(
        _ turns: [MeetingTurn], in meeting: MeetingID, expectedVersion: Int
    ) async throws -> Int {
        try reporting(meeting, reportSuccess: true) {
            let payload = try Self.encodeLines(turns) { MeetingStoreError.turnTooLarge($0.id) }
            let record = try mutate(meeting, expectedVersion: expectedVersion) { record in
                record.textRevision = (record.textRevision ?? 0) + 1
                try MeetingFileIO.atomicWrite(payload, to: fileURL(meeting, "turns.jsonl"))
                // Text edits belong to the old turns. Keep the speaker names.
                let names = try readEdits(meeting).speakerNames
                var kept = Data()
                let encoder = MeetingJSON.makeEncoder()
                for (label, name) in names.sorted(by: { $0.key.storageKey < $1.key.storageKey }) {
                    let line = MeetingEditLine(
                        kind: .speakerName, date: clock(), speaker: label, name: name,
                        turn: nil, text: nil)
                    kept.append(try encoder.encode(line))
                    kept.append(0x0A)
                }
                try MeetingFileIO.atomicWrite(kept, to: fileURL(meeting, "edits.jsonl"))
            }
            try reindex(meeting)
            return record.version
        }
    }

    @discardableResult
    public func editTurnText(
        _ turn: MeetingTurnID, to text: String, in meeting: MeetingID, expectedVersion: Int
    ) async throws -> Int {
        try reporting(meeting, reportSuccess: true) {
            guard try readTurns(meeting).turns.contains(where: { $0.id == turn }) else {
                throw MeetingStoreError.turnNotFound(turn)
            }
            let record = try mutate(meeting, expectedVersion: expectedVersion) { _ in
                let line = MeetingEditLine(
                    kind: .turnText, date: clock(), speaker: nil, name: nil, turn: turn,
                    text: text)
                try appendEdit(line, to: meeting)
            }
            try reindex(meeting)
            return record.version
        }
    }

    public func speakerNames(of meeting: MeetingID) async throws -> [MeetingSpeakerLabel: String] {
        _ = try loadRecord(meeting)
        return try readEdits(meeting).speakerNames
    }

    public func delete(_ meeting: MeetingID) async throws {
        try reporting(meeting, reportSuccess: true) {
            let folder = folderURL(meeting)
            if MeetingFileIO.lstatInfo(folder) != nil {
                // `removeItem` unlinks a symbolic link and never follows one.
                try FileManager.default.removeItem(at: folder)
            }
            index?.remove(meeting: meeting)
            removeDiagnosticsFiles(for: meeting)
        }
    }

    // MARK: Conversation

    @discardableResult
    public func appendConversation(
        _ entry: MeetingConversationEntry, to meeting: MeetingID
    ) async throws -> Int {
        try reporting(meeting, reportSuccess: false) {
            let record = try loadRecord(meeting)
            let check = try verify(entry.citations, in: meeting)
            var stored = entry
            stored.citations = check.verified
            if stored.textRevision == nil { stored.textRevision = record.textRevision ?? 0 }
            let payload = try Self.encodeLines([stored]) { _ in MeetingStoreError.entryTooLarge }
            try MeetingFileIO.append(payload, to: fileURL(meeting, "conversation.jsonl"))
            return check.failedCount
        }
    }

    public func conversation(of meeting: MeetingID) async throws -> [MeetingConversationEntry] {
        _ = try loadRecord(meeting)
        return try readConversation(meeting).entries
    }

    public func verifyCitations(
        _ citations: [MeetingCitation], in meeting: MeetingID
    ) async throws -> MeetingCitationCheck {
        _ = try loadRecord(meeting)
        return try verify(citations, in: meeting)
    }

    // MARK: Notes

    public func textRevision(of meeting: MeetingID) async throws -> Int {
        try loadRecord(meeting).textRevision ?? 0
    }

    public func summaryNotes(of meeting: MeetingID) async throws -> MeetingSummaryNotes? {
        _ = try loadRecord(meeting)
        return try readNotes(meeting)
    }

    @discardableResult
    public func saveSummaryNotes(
        _ notes: MeetingSummaryNotes, for meeting: MeetingID
    ) async throws -> Bool {
        try reporting(meeting, reportSuccess: true) {
            let record = try loadRecord(meeting)
            guard notes.schema == MeetingSummaryNotes.currentSchema,
                notes.textRevision == (record.textRevision ?? 0)
            else { return false }
            let data = try MeetingJSON.makeEncoder().encode(notes)
            guard data.count <= Self.notesFileLimit else { throw MeetingStoreError.entryTooLarge }
            try MeetingFileIO.atomicWrite(data, to: fileURL(meeting, "notes.json"))
            return true
        }
    }

    @discardableResult
    public func applyGeneratedTitle(_ title: String, to meeting: MeetingID) async throws -> Bool {
        try reporting(meeting, reportSuccess: true) {
            let record = try loadRecord(meeting)
            let cleaned = Self.cleanTitle(title)
            guard cleaned != Self.untitled else { return false }
            switch record.titleOrigin {
            case MeetingRecordFile.agentTitle?:
                break
            case nil:
                guard
                    MeetingSummaryTitleRule.isDefaultForm(record.title)
                        || record.title == Self.untitled
                else { return false }
            default:
                return false
            }
            guard cleaned != record.title || record.titleOrigin == nil else { return true }
            _ = try mutate(meeting, expectedVersion: record.version) {
                $0.title = cleaned
                $0.titleOrigin = MeetingRecordFile.agentTitle
            }
            try reindex(meeting)
            return true
        }
    }

    // MARK: Search

    public func search(_ query: String, limit: Int) async throws -> [MeetingSearchHit] {
        try ensureIndex()
        guard let index else { return [] }
        let rows = index.search(query, limit: limit)
        guard !rows.isEmpty else { return [] }
        let queryTokens = MeetingSearchTokenizer.tokens(in: query)
        var turnTextByMeeting: [MeetingID: [Int: String]] = [:]
        var titleByMeeting: [MeetingID: String] = [:]
        var hits: [MeetingSearchHit] = []
        for row in rows {
            if titleByMeeting[row.meeting] == nil {
                guard let record = try? loadRecord(row.meeting),
                    let turns = try? effectiveTurns(row.meeting).turns
                else { continue }
                titleByMeeting[row.meeting] = record.title
                turnTextByMeeting[row.meeting] = Dictionary(
                    turns.map { ($0.id.number, $0.text) }, uniquingKeysWith: { first, _ in first })
            }
            if row.turn < 0 {
                hits.append(
                    MeetingSearchHit(
                        meeting: row.meeting, turn: nil,
                        snippet: Self.snippet(titleByMeeting[row.meeting] ?? "", for: queryTokens)))
            } else if let text = turnTextByMeeting[row.meeting]?[row.turn] {
                hits.append(
                    MeetingSearchHit(
                        meeting: row.meeting, turn: MeetingTurnID(row.turn),
                        snippet: Self.snippet(text, for: queryTokens)))
            }
        }
        return hits
    }

    public func rebuildSearchIndex() async throws {
        index = nil
        try ensureIndex()
    }

    // MARK: Agent and export text

    public func agentPacketText(of meeting: MeetingID) async throws -> String {
        MeetingAgentText.packet(try loadDocument(meeting))
    }

    public func exportMarkdown(of meeting: MeetingID) async throws -> String {
        MeetingMarkdownExporter.export(try loadDocument(meeting))
    }

    public func exportMarkdown(
        of meeting: MeetingID, options: MeetingExportOptions
    ) async throws -> String {
        MeetingMarkdownExporter.export(try loadDocument(meeting), options: options)
    }

    public func document(of meeting: MeetingID) async throws -> MeetingDocument {
        try loadDocument(meeting)
    }

    public func makeAgentSnapshot(of meeting: MeetingID) async throws -> MeetingAgentSnapshot {
        let document = try loadDocument(meeting)
        try MeetingFileIO.ensurePrivateDirectory(snapshotRoot)
        let folder = snapshotRoot.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try MeetingFileIO.ensurePrivateDirectory(folder)
        let snapshot = MeetingAgentSnapshot(meeting: meeting, folder: folder)
        do {
            try MeetingFileIO.atomicWrite(
                Data(MeetingAgentText.overview(document).utf8), to: snapshot.overviewURL)
            try MeetingFileIO.atomicWrite(
                Data(MeetingAgentText.transcript(document).utf8), to: snapshot.transcriptURL)
        } catch {
            snapshot.remove()
            throw error
        }
        return snapshot
    }

    /// Removes snapshot folders older than `age` seconds, left by a crash.
    public func removeStaleSnapshots(olderThan age: TimeInterval = 3_600) {
        guard MeetingFileIO.isRealDirectory(snapshotRoot),
            let names = try? FileManager.default.contentsOfDirectory(atPath: snapshotRoot.path)
        else { return }
        let cutoff = clock().addingTimeInterval(-age)
        for name in names {
            let url = snapshotRoot.appending(path: name, directoryHint: .isDirectory)
            guard let info = MeetingFileIO.lstatInfo(url), (info.st_mode & S_IFMT) == S_IFDIR
            else { continue }
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    public func readReport(of meeting: MeetingID) async throws -> MeetingReadReport {
        _ = try loadRecord(meeting)
        return MeetingReadReport(
            skippedTurnLines: try readTurns(meeting).skipped,
            skippedEditLines: try readEdits(meeting).skippedLines,
            skippedConversationLines: try readConversation(meeting).skipped)
    }

    // MARK: Sizes and audio

    public func sizeOnDisk(of meeting: MeetingID) async throws -> MeetingSizes {
        try requireFolder(meeting)
        return sizes(of: meeting)
    }

    public func applyAudioRetention(_ retention: MeetingAudioRetention, now: Date) async throws {
        guard let days = retention.days else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var deletedFiles = 0
        for id in meetingIDs() {
            // Audio of a meeting that records or processes is still needed.
            guard let record = try? loadRecord(id) else { continue }
            switch record.state {
            case .recording, .paused, .processing: continue
            case .ready, .failed: break
            }
            for file in MeetingFileIO.regularFiles(in: audioURL(id)) where file.modified < cutoff {
                if unlink(MeetingFileIO.posixPath(file.url)) == 0 { deletedFiles += 1 }
            }
        }
        diagnostics.record(.libraryWrite(result: .written, code: deletedFiles), meeting: nil)
    }

    public func audioFolder(for meeting: MeetingID) async throws -> URL {
        try requireFolder(meeting)
        let folder = audioURL(meeting)
        try MeetingFileIO.ensurePrivateDirectory(folder)
        return folder
    }

    // MARK: Paths

    private func folderURL(_ id: MeetingID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func audioURL(_ id: MeetingID) -> URL {
        folderURL(id).appending(path: "audio", directoryHint: .isDirectory)
    }

    private func fileURL(_ id: MeetingID, _ name: String) -> URL {
        folderURL(id).appending(path: name, directoryHint: .notDirectory)
    }

    private func meetingIDs() -> [MeetingID] {
        guard MeetingFileIO.isRealDirectory(root),
            let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return [] }
        return names.compactMap { name in
            guard let id = MeetingID(uuidString: name), id.uuidString == name else { return nil }
            return MeetingFileIO.isRealDirectory(folderURL(id)) ? id : nil
        }
    }

    /// A meeting folder must be a real folder. A symbolic link is refused.
    private func requireFolder(_ id: MeetingID) throws {
        guard let info = MeetingFileIO.lstatInfo(folderURL(id)) else {
            throw MeetingStoreError.notFound(id)
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return
        case S_IFLNK: throw MeetingStoreError.symbolicLinkRefused
        default: throw MeetingStoreError.notFound(id)
        }
    }

    // MARK: Record

    private func loadRecord(_ id: MeetingID) throws -> MeetingRecordFile {
        try requireFolder(id)
        guard
            let data = try MeetingFileIO.readBounded(
                fileURL(id, "meeting.json"), maximumBytes: Self.recordFileLimit)
        else { throw MeetingStoreError.notFound(id) }
        guard
            let record = try? MeetingJSON.makeDecoder().decode(MeetingRecordFile.self, from: data),
            record.id == id
        else { throw MeetingStoreError.corruptRecord(id) }
        return record
    }

    private func writeRecord(_ record: MeetingRecordFile) throws {
        let data = try MeetingJSON.makeEncoder().encode(record)
        try MeetingFileIO.atomicWrite(data, to: fileURL(record.id, "meeting.json"))
    }

    private func check(_ record: MeetingRecordFile, expected: Int) throws {
        guard record.version == expected else {
            throw MeetingVersionConflict(
                meeting: record.id, expected: expected, found: record.version)
        }
    }

    /// Loads the record, checks the version, runs `change` (which can also
    /// do a side write that belongs to this change), bumps the version and
    /// writes the record atomically.
    private func mutate(
        _ id: MeetingID, expectedVersion: Int, _ change: (inout MeetingRecordFile) throws -> Void
    ) throws -> MeetingRecordFile {
        var record = try loadRecord(id)
        try check(record, expected: expectedVersion)
        try change(&record)
        record.version += 1
        try writeRecord(record)
        return record
    }

    private func summary(from record: MeetingRecordFile) -> MeetingSummaryRecord {
        MeetingSummaryRecord(
            id: record.id, title: record.title, startDate: record.startDate,
            duration: record.duration, state: record.state, sizes: sizes(of: record.id),
            engines: record.engines, version: record.version)
    }

    private func sizes(of id: MeetingID) -> MeetingSizes {
        let audio = MeetingFileIO.regularFiles(in: audioURL(id)).reduce(Int64(0)) { $0 + $1.size }
        let text = [
            "meeting.json", "turns.jsonl", "edits.jsonl", "conversation.jsonl", "notes.json",
        ]
        .reduce(Int64(0)) { $0 + MeetingFileIO.regularFileSize(fileURL(id, $1)) }
        return MeetingSizes(audioBytes: audio, transcriptBytes: text)
    }

    // MARK: Turns, edits, conversation

    private func readTurns(_ id: MeetingID) throws -> (turns: [MeetingTurn], skipped: Int) {
        guard
            let data = try MeetingFileIO.readBounded(
                fileURL(id, "turns.jsonl"), maximumBytes: Self.turnsFileLimit)
        else { return ([], 0) }
        let decoded = Self.decodeLines(data, as: MeetingTurn.self)
        return (decoded.values, decoded.skipped)
    }

    private func readEdits(_ id: MeetingID) throws -> MeetingEdits {
        guard
            let data = try MeetingFileIO.readBounded(
                fileURL(id, "edits.jsonl"), maximumBytes: Self.editsFileLimit)
        else { return MeetingEdits() }
        let decoded = Self.decodeLines(data, as: MeetingEditLine.self)
        var edits = MeetingEdits()
        for line in decoded.values { edits.apply(line) }
        edits.skippedLines = decoded.skipped
        return edits
    }

    private func readConversation(
        _ id: MeetingID
    ) throws -> (entries: [MeetingConversationEntry], skipped: Int) {
        guard
            let data = try MeetingFileIO.readBounded(
                fileURL(id, "conversation.jsonl"), maximumBytes: Self.conversationFileLimit)
        else { return ([], 0) }
        let decoded = Self.decodeLines(data, as: MeetingConversationEntry.self)
        return (decoded.values, decoded.skipped)
    }

    /// The notes, or nil when there is no file, it is damaged or it has
    /// another schema.
    private func readNotes(_ id: MeetingID) throws -> MeetingSummaryNotes? {
        guard
            let data = try MeetingFileIO.readBounded(
                fileURL(id, "notes.json"), maximumBytes: Self.notesFileLimit),
            let notes = try? MeetingJSON.makeDecoder().decode(MeetingSummaryNotes.self, from: data),
            notes.schema == MeetingSummaryNotes.currentSchema
        else { return nil }
        return notes
    }

    private func appendEdit(_ line: MeetingEditLine, to id: MeetingID) throws {
        let payload = try Self.encodeLines([line]) { _ in MeetingStoreError.entryTooLarge }
        try MeetingFileIO.append(payload, to: fileURL(id, "edits.jsonl"))
    }

    /// The turns with the text edits applied. Ids never change.
    private func effectiveTurns(
        _ id: MeetingID
    ) throws -> (turns: [MeetingTurn], edits: MeetingEdits) {
        let edits = try readEdits(id)
        var turns = try readTurns(id).turns
        if !edits.turnTexts.isEmpty {
            for position in turns.indices {
                if let text = edits.turnTexts[turns[position].id] { turns[position].text = text }
            }
        }
        return (turns, edits)
    }

    private func loadDocument(_ id: MeetingID) throws -> MeetingDocument {
        let record = try loadRecord(id)
        let effective = try effectiveTurns(id)
        return MeetingDocument(
            summary: summary(from: record), turns: effective.turns,
            speakerNames: effective.edits.speakerNames,
            conversation: try readConversation(id).entries)
    }

    private func verify(
        _ citations: [MeetingCitation], in id: MeetingID
    ) throws -> MeetingCitationCheck {
        let known = Set(try readTurns(id).turns.map(\.id))
        let verified = citations.filter { known.contains($0.turn) }
        return MeetingCitationCheck(
            verified: verified, failedCount: citations.count - verified.count)
    }

    // MARK: Index

    private func ensureIndex() throws {
        guard index == nil else { return }
        let started = ContinuousClock.now
        var built = MeetingSearchIndex()
        for id in meetingIDs() {
            guard let record = try? loadRecord(id), let effective = try? effectiveTurns(id) else {
                continue
            }
            built.replace(
                meeting: id, title: record.title, startDate: record.startDate,
                turns: effective.turns.map { ($0.id, $0.text) })
        }
        index = built
        let elapsed = ContinuousClock.now - started
        let milliseconds =
            Int(elapsed.components.seconds * 1_000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        diagnostics.record(
            .libraryIndexRebuilt(meetings: built.meetingCount, wallMilliseconds: milliseconds),
            meeting: nil)
    }

    /// Makes the rows of one meeting again from its files (after a title
    /// change, an edit or a replaced transcript).
    private func reindex(_ id: MeetingID) throws {
        guard index != nil else { return }
        let record = try loadRecord(id)
        let effective = try effectiveTurns(id)
        index?.replace(
            meeting: id, title: record.title, startDate: record.startDate,
            turns: effective.turns.map { ($0.id, $0.text) })
    }

    // MARK: Diagnostics

    private func removeDiagnosticsFiles(for id: MeetingID) {
        for name in ["\(id.uuidString).jsonl", "\(id.uuidString).1.jsonl"] {
            let url = diagnosticsDirectory.appending(path: name, directoryHint: .notDirectory)
            if MeetingFileIO.lstatInfo(url) != nil { unlink(MeetingFileIO.posixPath(url)) }
        }
    }

    /// Runs one write and records a counts-and-codes event for it. A success
    /// is reported only when `reportSuccess` is true (an append runs often).
    private func reporting<T>(
        _ meeting: MeetingID?, reportSuccess: Bool, _ body: () throws -> T
    ) throws -> T {
        do {
            let value = try body()
            if reportSuccess {
                diagnostics.record(.libraryWrite(result: .written, code: nil), meeting: meeting)
            }
            return value
        } catch let conflict as MeetingVersionConflict {
            diagnostics.record(.libraryWrite(result: .conflict, code: nil), meeting: meeting)
            throw conflict
        } catch {
            diagnostics.record(
                .libraryWrite(result: .failed, code: Self.diagnosticCode(error)), meeting: meeting)
            throw error
        }
    }

    static func diagnosticCode(_ error: any Error) -> Int {
        guard let error = error as? MeetingStoreError else { return 0 }
        switch error {
        case .io(let code): return Int(code)
        case .notFound: return -1
        case .symbolicLinkRefused: return -2
        case .notARegularFile: return -3
        case .fileTooLarge: return -4
        case .corruptRecord: return -5
        case .turnTooLarge: return -6
        case .entryTooLarge: return -7
        case .turnNotFound: return -8
        }
    }

    // MARK: Coding helpers

    /// One JSON object for each line. A line over the limit is refused with
    /// the error that `tooLarge` makes.
    private static func encodeLines<Value: Encodable>(
        _ values: [Value], tooLarge: (Value) -> MeetingStoreError
    ) throws -> Data {
        let encoder = MeetingJSON.makeEncoder()
        var payload = Data()
        for value in values {
            let line = try encoder.encode(value)
            guard line.count < MeetingFileIO.maximumLineBytes else { throw tooLarge(value) }
            payload.append(line)
            payload.append(0x0A)
        }
        return payload
    }

    /// Decodes each line. A damaged line or a line over the limit is
    /// skipped and counted.
    private static func decodeLines<Value: Decodable>(
        _ data: Data, as type: Value.Type
    ) -> (values: [Value], skipped: Int) {
        let split = MeetingFileIO.lines(of: data)
        let decoder = MeetingJSON.makeDecoder()
        var values: [Value] = []
        var skipped = split.skipped
        for line in split.lines {
            if let value = try? decoder.decode(Value.self, from: line) {
                values.append(value)
            } else {
                skipped += 1
            }
        }
        return (values, skipped)
    }

    // MARK: Text cleaning

    static func cleanTitle(_ raw: String) -> String {
        let cleaned = cleanLine(raw, limit: maximumTitleCharacters)
        return cleaned.isEmpty ? untitled : cleaned
    }

    /// A speaker name. An empty result clears the rename.
    static func cleanName(_ raw: String) -> String {
        cleanLine(raw, limit: maximumNameCharacters)
    }

    private static func cleanLine(_ raw: String, limit: Int) -> String {
        var result = ""
        for character in raw {
            if character.unicodeScalars.contains(where: {
                $0.properties.generalCategory == .control
                    || $0.properties.generalCategory == .lineSeparator
                    || $0.properties.generalCategory == .paragraphSeparator
            }) {
                result.append(" ")
            } else {
                result.append(character)
            }
            if result.count >= limit { break }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// About 120 characters of `text` around the first word that matches the
    /// query, with an ellipsis at a cut end.
    static func snippet(_ text: String, for queryTokens: [String]) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let limit = 120
        guard flat.count > limit else { return flat }
        var start = flat.startIndex
        if let first = queryTokens.first,
            let range = flat.range(
                of: first, options: [.caseInsensitive, .diacriticInsensitive])
        {
            start =
                flat.index(range.lowerBound, offsetBy: -40, limitedBy: flat.startIndex)
                ?? flat.startIndex
        }
        let end = flat.index(start, offsetBy: limit, limitedBy: flat.endIndex) ?? flat.endIndex
        var result = String(flat[start..<end])
        if start > flat.startIndex { result = "…" + result }
        if end < flat.endIndex { result += "…" }
        return result
    }
}
