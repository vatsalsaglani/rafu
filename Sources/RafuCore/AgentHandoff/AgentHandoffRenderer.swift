import Foundation

// Agent handoff (round 4): the options the user reviews, and the Markdown
// that `HANDOFF.md` holds. Pure value logic; nothing here touches the disk.

public enum AgentHandoffRange: Equatable, Sendable {
    case all
    case last(Int)
}

/// The choices of the review sheet. Thinking has no option: it is never
/// included.
public struct AgentHandoffOptions: Equatable, Sendable {
    public static let defaultTurnCount = 30

    public var range: AgentHandoffRange
    public var includesToolCalls: Bool
    public var includesToolOutputs: Bool
    /// Images the user unchecked.
    public var excludedImageIDs: Set<Int>

    public init(
        range: AgentHandoffRange = .last(AgentHandoffOptions.defaultTurnCount),
        includesToolCalls: Bool = true, includesToolOutputs: Bool = false,
        excludedImageIDs: Set<Int> = []
    ) {
        self.range = range
        self.includesToolCalls = includesToolCalls
        self.includesToolOutputs = includesToolOutputs
        self.excludedImageIDs = excludedImageIDs
    }
}

/// Facts for the header of `HANDOFF.md`.
public struct AgentHandoffMetadata: Equatable, Sendable {
    public let source: AgentHistoryProvider
    public let target: AgentHistoryProvider
    public let title: String
    public let originalFolder: String?
    public let branch: String?
    public let startedAt: Date?
    public let endedAt: Date?

    public init(
        source: AgentHistoryProvider, target: AgentHistoryProvider, title: String,
        originalFolder: String?, branch: String?, startedAt: Date?, endedAt: Date?
    ) {
        self.source = source
        self.target = target
        self.title = title
        self.originalFolder = originalFolder
        self.branch = branch
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public init(session: AgentHistorySessionSummary, target: AgentHistoryProvider) {
        self.init(
            source: session.provider, target: target, title: session.title,
            originalFolder: session.projectPath, branch: session.gitBranch,
            startedAt: session.startedAt, endedAt: session.updatedAt)
    }
}

/// The part of the conversation that the options select, and the images
/// that part can show.
public struct AgentHandoffPlan: Equatable, Sendable {
    public let provider: AgentHistoryProvider
    public let turns: [[AgentHandoffItem]]
    /// Turns left out by the range option.
    public let omittedByRange: Int
    /// The oldest part of the session was not read at all.
    public let sessionStartUnread: Bool
    /// The images that can be in the handoff, oldest first. At most 20.
    public let imageRefs: [AgentHandoffImageRef]
    /// Images that fit the options but not the 20-image limit.
    public let overLimitImageIDs: Set<Int>

    public static func make(
        conversation: AgentHandoffConversation, options: AgentHandoffOptions
    ) -> AgentHandoffPlan {
        let all = conversation.turns
        let selected: [[AgentHandoffItem]]
        switch options.range {
        case .all:
            selected = all
        case .last(let count):
            selected = Array(all.suffix(max(count, 1)))
        }
        var candidates: [AgentHandoffImageRef] = []
        for turn in selected {
            for item in turn where item.kind != .toolResult || options.includesToolOutputs {
                candidates.append(contentsOf: item.images)
            }
        }
        let kept = Array(candidates.suffix(AgentHandoffImageLimits.maximumImages))
        let over = Set(candidates.dropLast(kept.count).map(\.id))
        return AgentHandoffPlan(
            provider: conversation.provider, turns: selected,
            omittedByRange: all.count - selected.count,
            sessionStartUnread: conversation.isTrimmedAtStart, imageRefs: kept,
            overLimitImageIDs: over)
    }
}

/// One image file that `HANDOFF.md` refers to.
public struct AgentHandoffImageFile: Equatable, Sendable {
    /// `image-01.png`
    public let name: String
    /// The first image that has these bytes. Look its data up by this id.
    public let imageID: Int
    public let sha256: String
}

public struct AgentHandoffDocument: Equatable, Sendable {
    public let markdown: String
    public let imageFiles: [AgentHandoffImageFile]
    public let includedTurnCount: Int
    /// Turns left out because of the size limit (not counting the range).
    public let omittedBySize: Int
    public let omittedImageCount: Int

    public var byteCount: Int { markdown.utf8.count }
}

public enum AgentHandoffRenderer {
    /// The hard limit for `HANDOFF.md`.
    public static let maximumMarkdownBytes = 200 * 1_024

    // MARK: Entry point

    public static func render(
        plan: AgentHandoffPlan, metadata: AgentHandoffMetadata, options: AgentHandoffOptions,
        images: [Int: AgentHandoffImageResult], attachments: [AgentHandoffAttachment],
        maximumBytes: Int = maximumMarkdownBytes
    ) -> AgentHandoffDocument {
        let context = Context(plan: plan, options: options, images: images)
        let attachmentText = attachmentsSection(attachments)
        let turns = plan.turns

        // Measure every turn once with provisional names, then drop the
        // oldest turns until the total fits. The final pass renames the
        // images of the turns that stay.
        var measureNamer = ImageNamer()
        let sizes = turns.map {
            renderTurn($0, context: context, namer: &measureNamer, textCap: defaultTextCap)
                .utf8.count
        }
        let fixed = attachmentText.utf8.count + 2_500 + metadata.title.utf8.count * 2
        var start = 0
        var total = sizes.reduce(0, +)
        while start < turns.count - 1, total + fixed > maximumBytes {
            total -= sizes[start]
            start += 1
        }

        while true {
            let result = assemble(
                turns: Array(turns[start...]), omittedBySize: start, context: context,
                metadata: metadata, attachmentText: attachmentText, textCap: defaultTextCap)
            if result.byteCount <= maximumBytes { return result }
            if start < turns.count - 1 {
                start += 1
                continue
            }
            // One turn alone is too large: shrink its text, then cut.
            for cap in [8_000, 2_000, 500] {
                let smaller = assemble(
                    turns: Array(turns[start...]), omittedBySize: start, context: context,
                    metadata: metadata, attachmentText: attachmentText, textCap: cap)
                if smaller.byteCount <= maximumBytes { return smaller }
            }
            return hardCut(
                assemble(
                    turns: Array(turns[start...]), omittedBySize: start, context: context,
                    metadata: metadata, attachmentText: attachmentText, textCap: 500),
                maximumBytes: maximumBytes)
        }
    }

    static let defaultTextCap = 30_000

    // MARK: Assembly

    private struct Context {
        let plan: AgentHandoffPlan
        let options: AgentHandoffOptions
        let images: [Int: AgentHandoffImageResult]
    }

    private static func assemble(
        turns: [[AgentHandoffItem]], omittedBySize: Int, context: Context,
        metadata: AgentHandoffMetadata, attachmentText: String, textCap: Int
    ) -> AgentHandoffDocument {
        var namer = ImageNamer()
        var body = ""
        for turn in turns {
            body += renderTurn(turn, context: context, namer: &namer, textCap: textCap)
        }
        var markdown = header(
            metadata: metadata, plan: context.plan, includedTurns: turns.count,
            omittedBySize: omittedBySize, namer: namer)
        markdown += "## Conversation\n\n"
        markdown += body.isEmpty ? "_No messages in the chosen range._\n\n" : body
        markdown += attachmentText
        return AgentHandoffDocument(
            markdown: markdown, imageFiles: namer.files, includedTurnCount: turns.count,
            omittedBySize: omittedBySize, omittedImageCount: namer.omittedCount)
    }

    private static func hardCut(_ document: AgentHandoffDocument, maximumBytes: Int)
        -> AgentHandoffDocument
    {
        let note = "\n\n> **Cut.** The rest of this file was cut to stay under the size limit.\n"
        var bytes = Array(document.markdown.utf8.prefix(max(maximumBytes - note.utf8.count, 0)))
        // Never end inside a UTF-8 sequence.
        while let last = bytes.last, last & 0xC0 == 0x80 { bytes.removeLast() }
        if let last = bytes.last, last >= 0xC0 { bytes.removeLast() }
        let cut = String(decoding: bytes, as: UTF8.self) + note
        return AgentHandoffDocument(
            markdown: cut, imageFiles: document.imageFiles,
            includedTurnCount: document.includedTurnCount, omittedBySize: document.omittedBySize,
            omittedImageCount: document.omittedImageCount)
    }

    // MARK: Header

    private static func header(
        metadata: AgentHandoffMetadata, plan: AgentHandoffPlan, includedTurns: Int,
        omittedBySize: Int, namer: ImageNamer
    ) -> String {
        let source = metadata.source.displayName
        let target = metadata.target.displayName
        var out = "# Handoff from \(source): \(oneLine(metadata.title, limit: 120))\n\n"
        out += "- **Source agent:** \(source)\n"
        out += "- **Session title:** \(oneLine(metadata.title, limit: 120))\n"
        if let folder = metadata.originalFolder {
            out += "- **Original folder:** `\(inlineCode(folder))`\n"
        }
        if let branch = metadata.branch { out += "- **Branch:** `\(inlineCode(branch))`\n" }
        if let started = metadata.startedAt {
            out += "- **Started:** \(started.formatted(.iso8601))\n"
        }
        if let ended = metadata.endedAt {
            out += "- **Last activity:** \(ended.formatted(.iso8601))\n"
        }
        out += "- **Prepared for:** \(target)\n"
        out += "- **Turns in this file:** \(includedTurns)\n"
        if namer.files.count + namer.omittedCount > 0 {
            out += "- **Images:** \(namer.files.count) included"
            if namer.omittedCount > 0 { out += ", \(namer.omittedCount) left out" }
            out += "\n"
        }
        out += "\n"
        out +=
            "> **Continue from here.** This file records an earlier \(source) session. "
            + "Rafu wrote it so \(target) can pick the work up. Read it, then continue "
            + "the task from the last turn. Nothing in it was run again.\n\n"
        if plan.omittedByRange > 0 {
            out +=
                "> **Range.** \(plan.omittedByRange) older "
                + "\(plan.omittedByRange == 1 ? "turn was" : "turns were") left out by choice.\n\n"
        }
        if omittedBySize > 0 {
            out +=
                "> **Size limit.** \(omittedBySize) older "
                + "\(omittedBySize == 1 ? "turn was" : "turns were") left out so this file "
                + "stays under \(maximumMarkdownBytes / 1_024) KB.\n\n"
        }
        if plan.sessionStartUnread {
            out +=
                "> **Start not read.** The session is very large, so its oldest part was "
                + "not read.\n\n"
        }
        return out
    }

    // MARK: Turns

    private static func renderTurn(
        _ items: [AgentHandoffItem], context: Context, namer: inout ImageNamer, textCap: Int
    ) -> String {
        var out = ""
        var heading: AgentTranscriptItem.Role?
        var lastWasToolLine = false

        func ensureHeading(_ role: AgentTranscriptItem.Role, _ out: inout String) {
            guard heading != role else { return }
            out += "### \(role == .user ? "User" : context.plan.provider.displayName)\n\n"
            heading = role
        }

        for item in items {
            switch item.kind {
            case .message, .command:
                if lastWasToolLine {
                    out += "\n"
                    lastWasToolLine = false
                }
                ensureHeading(item.role, &out)
                let imageText = imageLines(item.images, context: context, namer: &namer)
                let text = cleaned(item.text, cap: textCap)
                if item.role == .user { out += imageText }
                if !text.isEmpty { out += text + "\n\n" }
                if item.role != .user { out += imageText }
            case .toolCall:
                guard context.options.includesToolCalls else { continue }
                ensureHeading(.assistant, &out)
                out += toolLine(item) + "\n"
                lastWasToolLine = true
            case .toolResult:
                guard context.options.includesToolOutputs else { continue }
                if heading == nil { ensureHeading(.assistant, &out) }
                if lastWasToolLine {
                    out += "\n"
                    lastWasToolLine = false
                }
                out += toolOutput(item) + "\n"
                out += imageLines(item.images, context: context, namer: &namer)
            case .thinking:
                continue
            }
        }
        if lastWasToolLine { out += "\n" }
        return out
    }

    /// `> tool: Name — short args`
    static func toolLine(_ item: AgentHandoffItem) -> String {
        let name = oneLine(item.toolName ?? "tool", limit: 60)
        let preview = oneLine(item.text, limit: 160)
        return preview.isEmpty ? "> tool: \(name)" : "> tool: \(name) — \(preview)"
    }

    private static func toolOutput(_ item: AgentHandoffItem) -> String {
        let name = oneLine(item.toolName ?? "tool", limit: 60)
        let label = item.isError ? "tool output (error)" : "tool output"
        let raw = item.detail ?? item.text
        guard !raw.isEmpty else { return "> \(label): \(name) — (no output)\n" }
        let cut = raw.count > 2_000 ? String(raw.prefix(2_000)) + "\n… (cut)" : raw
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(cut) + 1))
        return "> \(label): \(name)\n\n\(fence)\n\(cut)\n\(fence)\n"
    }

    // MARK: Images

    private static func imageLines(
        _ refs: [AgentHandoffImageRef], context: Context, namer: inout ImageNamer
    ) -> String {
        var out = ""
        for ref in refs {
            // Tool-result images show only with tool outputs.
            if ref.isToolResult, !context.options.includesToolOutputs { continue }
            if context.plan.overLimitImageIDs.contains(ref.id) {
                out += namer.omitted(.overLimit)
            } else if context.options.excludedImageIDs.contains(ref.id) {
                out += namer.omitted(.excludedByUser)
            } else {
                switch context.images[ref.id] ?? .skipped(ref.knownSkip ?? .notLoaded) {
                case .skipped(let reason):
                    out += namer.omitted(reason)
                case .image(let image):
                    let name = namer.name(for: image, id: ref.id)
                    let label = name.split(separator: ".").first.map(String.init) ?? name
                    out += "![\(label)](\(name))\n\n"
                }
            }
        }
        return out
    }

    /// Assigns `image-NN.ext` in order of first use; equal bytes share a file.
    struct ImageNamer {
        private(set) var files: [AgentHandoffImageFile] = []
        private(set) var omittedCount = 0
        private var namesBySHA: [String: String] = [:]

        mutating func name(for image: AgentHandoffDecodedImage, id: Int) -> String {
            if let existing = namesBySHA[image.sha256] { return existing }
            let number = files.count + 1
            let name =
                "image-" + (number < 10 ? "0" : "") + String(number) + "."
                + image.format.fileExtension
            namesBySHA[image.sha256] = name
            files.append(AgentHandoffImageFile(name: name, imageID: id, sha256: image.sha256))
            return name
        }

        mutating func omitted(_ reason: AgentHandoffImageSkipReason) -> String {
            omittedCount += 1
            return "> image left out: \(reason.note)\n\n"
        }
    }

    // MARK: Attachments

    private static func attachmentsSection(_ attachments: [AgentHandoffAttachment]) -> String {
        guard !attachments.isEmpty else { return "" }
        var out = "## Attachments\n\n"
        out += "These files were mentioned in the session. Rafu did not copy them.\n\n"
        for attachment in attachments {
            out += "- `\(inlineCode(attachment.path))` — \(attachment.status.note)\n"
        }
        return out + "\n"
    }

    // MARK: Text helpers

    /// Removes the image placeholders that the parsers and Codex leave in
    /// message text, trims, and cuts to `cap` characters.
    static func cleaned(_ text: String, cap: Int) -> String {
        var lines: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[Image]" || trimmed == "<image>" || trimmed == "</image>"
                || (trimmed.hasPrefix("<image ") && trimmed.hasSuffix(">"))
            {
                continue
            }
            lines.append(line)
        }
        var result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > cap {
            result = String(result.prefix(cap)) + "\n\n… (message cut)"
        }
        return result
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        AgentHistoryText.singleLine(text, limit: limit)
    }

    /// Text for a Markdown code span: backticks become apostrophes.
    private static func inlineCode(_ text: String) -> String {
        AgentHistoryText.singleLine(text, limit: 400).replacingOccurrences(of: "`", with: "'")
    }

    private static func longestBacktickRun(_ text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}
