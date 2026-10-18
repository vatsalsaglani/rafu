import Foundation
import Testing

@testable import RafuCore

private typealias Fixtures = AgentHandoffFixtures

private func conversation(_ items: [AgentHandoffItem], provider: AgentHistoryProvider = .claudeCode)
    -> AgentHandoffConversation
{
    AgentHandoffConversation(provider: provider, items: items)
}

private func render(
    _ items: [AgentHandoffItem], options: AgentHandoffOptions = AgentHandoffOptions(),
    images: [Int: AgentHandoffImageResult] = [:], attachments: [AgentHandoffAttachment] = [],
    provider: AgentHistoryProvider = .claudeCode, maximumBytes: Int = 200 * 1_024
) -> AgentHandoffDocument {
    let plan = AgentHandoffPlan.make(
        conversation: conversation(items, provider: provider), options: options)
    return AgentHandoffRenderer.render(
        plan: plan, metadata: Fixtures.metadata(source: provider), options: options,
        images: images, attachments: attachments, maximumBytes: maximumBytes)
}

@Test func handoffMarkdownKeepsTurnOrderAndHeadings() {
    let document = render([
        Fixtures.prompt("first question"),
        Fixtures.reply("first answer"),
        Fixtures.prompt("second question"),
        Fixtures.reply("second answer"),
    ])
    let text = document.markdown
    let user1 = text.range(of: "### User\n\nfirst question")
    let reply1 = text.range(of: "### Claude Code\n\nfirst answer")
    let user2 = text.range(of: "### User\n\nsecond question")
    let reply2 = text.range(of: "### Claude Code\n\nsecond answer")
    #expect(user1 != nil && reply1 != nil && user2 != nil && reply2 != nil)
    if let user1, let reply1, let user2, let reply2 {
        #expect(user1.lowerBound < reply1.lowerBound)
        #expect(reply1.lowerBound < user2.lowerBound)
        #expect(user2.lowerBound < reply2.lowerBound)
    }
    #expect(document.includedTurnCount == 2)
}

@Test func handoffMarkdownHeaderNamesTheSessionAndTheContinueNote() {
    let document = render([Fixtures.prompt("hi")])
    let text = document.markdown
    #expect(text.hasPrefix("# Handoff from Claude Code: Fix the login bug\n"))
    #expect(text.contains("- **Source agent:** Claude Code"))
    #expect(text.contains("- **Original folder:** `/work/alpha`"))
    #expect(text.contains("- **Branch:** `main`"))
    #expect(text.contains("- **Started:** 2026-01-02T"))
    #expect(text.contains("- **Last activity:** 2026-01-02T"))
    #expect(text.contains("- **Prepared for:** Codex"))
    #expect(text.contains("> **Continue from here.**"))
}

@Test func handoffMarkdownUsesTheSourceAgentNameForReplies() {
    let document = render(
        [Fixtures.prompt("hi"), Fixtures.reply("hello")], provider: .codex)
    #expect(document.markdown.contains("### Codex\n\nhello"))
    #expect(!document.markdown.contains("### Claude Code"))
}

@Test func handoffToolCallsUseOneQuotedLineEach() {
    let items = [
        Fixtures.prompt("go"),
        Fixtures.tool("Read", "Sources/App.swift"),
        Fixtures.tool("Bash", "swift test"),
        Fixtures.reply("done"),
    ]
    let on = render(items)
    #expect(on.markdown.contains("> tool: Read — Sources/App.swift\n> tool: Bash — swift test\n"))
    let off = render(items, options: AgentHandoffOptions(includesToolCalls: false))
    #expect(!off.markdown.contains("> tool:"))
    #expect(off.markdown.contains("done"))
}

@Test func handoffToolLineHasNoArgumentsWhenThePreviewIsEmpty() {
    #expect(AgentHandoffRenderer.toolLine(Fixtures.tool("TodoWrite", "")) == "> tool: TodoWrite")
    // A multi-line preview still gives one line.
    #expect(
        AgentHandoffRenderer.toolLine(Fixtures.tool("Bash", "line one\nline two"))
            == "> tool: Bash — line one line two")
}

@Test func handoffToolOutputsAreOffByDefaultAndFencedWhenOn() {
    let items = [
        Fixtures.prompt("go"),
        Fixtures.tool("Bash", "echo"),
        Fixtures.toolResult("Bash", "line with ``` fence"),
    ]
    #expect(!render(items).markdown.contains("tool output"))
    let on = render(items, options: AgentHandoffOptions(includesToolOutputs: true))
    #expect(on.markdown.contains("> tool output: Bash"))
    // The fence is longer than the longest run inside the output.
    #expect(on.markdown.contains("````\nline with ``` fence\n````"))
}

@Test func handoffNeverWritesThinking() {
    let items = [
        Fixtures.prompt("go"),
        AgentHandoffItem(role: .assistant, kind: .thinking, text: "PRIVATE REASONING"),
        Fixtures.reply("answer"),
    ]
    for options in [
        AgentHandoffOptions(),
        AgentHandoffOptions(range: .all, includesToolCalls: true, includesToolOutputs: true),
    ] {
        #expect(!render(items, options: options).markdown.contains("PRIVATE REASONING"))
    }
}

@Test func handoffPlacesImagesInlineAtTheirPosition() {
    let png = Fixtures.pngData()
    let jpeg = Fixtures.jpegData()
    let items = [
        Fixtures.prompt("look at this\n\n[Image]", images: [Fixtures.ref(1)]),
        Fixtures.reply("I see it", images: [Fixtures.ref(2)]),
    ]
    let document = render(
        items, images: [1: Fixtures.decoded(png), 2: Fixtures.decoded(jpeg)])
    let text = document.markdown
    let firstImage = text.range(of: "![image-01](image-01.png)")
    let promptText = text.range(of: "look at this")
    let replyText = text.range(of: "I see it")
    let secondImage = text.range(of: "![image-02](image-02.jpg)")
    #expect(firstImage != nil && promptText != nil && replyText != nil && secondImage != nil)
    if let firstImage, let promptText, let replyText, let secondImage {
        // A prompt shows its images first; a reply shows them after its text.
        #expect(firstImage.lowerBound < promptText.lowerBound)
        #expect(replyText.lowerBound < secondImage.lowerBound)
    }
    // The placeholder text never reaches the file.
    #expect(!text.contains("[Image]"))
    #expect(document.imageFiles.map(\.name) == ["image-01.png", "image-02.jpg"])
    #expect(document.imageFiles.map(\.imageID) == [1, 2])
}

@Test func handoffSharesOneFileForDuplicateImages() {
    let png = Fixtures.pngData()
    let items = [
        Fixtures.prompt("one", images: [Fixtures.ref(1)]),
        Fixtures.prompt("two", images: [Fixtures.ref(2)]),
    ]
    let document = render(
        items, images: [1: Fixtures.decoded(png), 2: Fixtures.decoded(png)])
    #expect(document.imageFiles.count == 1)
    #expect(document.markdown.components(separatedBy: "(image-01.png)").count - 1 == 2)
}

@Test func handoffNotesImagesThatAreLeftOut() {
    let png = Fixtures.pngData()
    let items = [
        Fixtures.prompt(
            "a", images: [Fixtures.ref(1), Fixtures.ref(2), Fixtures.ref(3), Fixtures.ref(4)])
    ]
    let document = render(
        items,
        options: AgentHandoffOptions(excludedImageIDs: [2]),
        images: [
            1: Fixtures.decoded(png), 2: Fixtures.decoded(png),
            3: .skipped(.tooLarge),
        ])
    #expect(document.imageFiles.count == 1)
    #expect(document.omittedImageCount == 3)
    #expect(document.markdown.contains("> image left out: left out in the review"))
    #expect(document.markdown.contains("> image left out: larger than 5 MB"))
    #expect(document.markdown.contains("> image left out: not loaded"))
    #expect(document.markdown.contains("- **Images:** 1 included, 3 left out"))
}

@Test func handoffKeepsOnlyTheNewestTwentyImages() {
    let refs = (0..<25).map { Fixtures.ref($0) }
    let items = [Fixtures.prompt("many", images: refs)]
    let plan = AgentHandoffPlan.make(
        conversation: conversation(items), options: AgentHandoffOptions())
    #expect(plan.imageRefs.map(\.id) == Array(5..<25))
    #expect(plan.overLimitImageIDs == Set(0..<5))
    var images: [Int: AgentHandoffImageResult] = [:]
    for id in 0..<25 { images[id] = Fixtures.decoded(Fixtures.pngData(salt: UInt8(id))) }
    let document = render(items, images: images)
    #expect(document.imageFiles.count == 20)
    #expect(document.omittedImageCount == 5)
}

@Test func handoffToolResultImagesNeedToolOutputs() {
    let items = [
        Fixtures.prompt("go"),
        Fixtures.toolResult("Read", "bytes", images: [Fixtures.ref(7, tool: true)]),
    ]
    let images: [Int: AgentHandoffImageResult] = [7: Fixtures.decoded(Fixtures.pngData())]
    let off = render(items, images: images)
    #expect(off.imageFiles.isEmpty)
    let plan = AgentHandoffPlan.make(
        conversation: conversation(items), options: AgentHandoffOptions())
    #expect(plan.imageRefs.isEmpty)
    let on = render(
        items, options: AgentHandoffOptions(includesToolOutputs: true), images: images)
    #expect(on.imageFiles.count == 1)
}

@Test func handoffLastNTurnsDropsTheOlderOnes() {
    var items: [AgentHandoffItem] = []
    for index in 1...5 {
        items.append(Fixtures.prompt("question \(index)"))
        items.append(Fixtures.reply("answer \(index)"))
    }
    let options = AgentHandoffOptions(range: .last(2))
    let document = render(items, options: options)
    #expect(document.includedTurnCount == 2)
    #expect(!document.markdown.contains("question 3"))
    #expect(document.markdown.contains("question 4"))
    #expect(document.markdown.contains("3 older turns were left out by choice"))
    let all = render(items, options: AgentHandoffOptions(range: .all))
    #expect(all.includedTurnCount == 5)
}

@Test func handoffSizeCapDropsTheOldestTurnsAndSaysSo() {
    var items: [AgentHandoffItem] = []
    for index in 1...30 {
        items.append(Fixtures.prompt("question \(index)"))
        items.append(Fixtures.reply("answer \(index) " + String(repeating: "x", count: 2_000)))
    }
    let document = render(
        items, options: AgentHandoffOptions(range: .all), maximumBytes: 20_000)
    #expect(document.byteCount <= 20_000)
    #expect(document.omittedBySize > 0)
    #expect(document.markdown.contains("older turns were left out so this file stays under"))
    // Newest turns stay; oldest go.
    #expect(document.markdown.contains("question 30"))
    #expect(!document.markdown.contains("question 1\n"))
    #expect(document.includedTurnCount + document.omittedBySize == 30)
}

@Test func handoffSizeCapShrinksOneHugeTurn() {
    let items = [
        Fixtures.prompt("question"),
        Fixtures.reply(String(repeating: "word ", count: 20_000)),
    ]
    let document = render(items, maximumBytes: 10_000)
    #expect(document.byteCount <= 10_000)
    #expect(document.markdown.contains("question"))
}

@Test func handoffSizeCapNeverSplitsMultiByteText() {
    let items = [
        Fixtures.prompt("q"),
        Fixtures.reply(String(repeating: "日本語🙂", count: 30_000)),
    ]
    let document = render(items, maximumBytes: 6_000)
    #expect(document.byteCount <= 6_000)
    // Valid UTF-8 by construction: re-encoding gives the same bytes.
    #expect(Data(document.markdown.utf8).count == document.byteCount)
}

@Test func handoffMarkdownListsAttachmentsWithTheirStatus() {
    let document = render(
        [Fixtures.prompt("hi")],
        attachments: [
            AgentHandoffAttachment(path: "Sources/App.swift", status: .inProject),
            AgentHandoffAttachment(path: "/Users/x/spec.pdf", status: .outsideProject),
            AgentHandoffAttachment(path: "docs/gone.md", status: .missing),
        ])
    let text = document.markdown
    #expect(text.contains("## Attachments"))
    #expect(text.contains("- `Sources/App.swift` — available in the project"))
    #expect(text.contains("- `/Users/x/spec.pdf` — outside the project — not copied"))
    #expect(text.contains("- `docs/gone.md` — missing"))
    #expect(!render([Fixtures.prompt("hi")]).markdown.contains("## Attachments"))
}

@Test func handoffMarkdownNotesAnUnreadSessionStart() {
    let big = AgentHandoffConversation(
        provider: .codex, items: [Fixtures.prompt("late")], droppedLeadingItems: 10)
    let plan = AgentHandoffPlan.make(conversation: big, options: AgentHandoffOptions())
    let document = AgentHandoffRenderer.render(
        plan: plan, metadata: Fixtures.metadata(source: .codex, target: .claudeCode),
        options: AgentHandoffOptions(), images: [:], attachments: [])
    #expect(document.markdown.contains("> **Start not read.**"))
}

@Test func handoffCleaningRemovesImagePlaceholdersOnly() {
    let text = "[Image]\n<image name=[Image #1]>\n</image>\nkeep [Image] inline\n<image>"
    #expect(AgentHandoffRenderer.cleaned(text, cap: 1_000) == "keep [Image] inline")
    #expect(AgentHandoffRenderer.cleaned("abcdef", cap: 3).hasPrefix("abc\n\n"))
}
