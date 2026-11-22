import Foundation
import Testing

@testable import RafuCore

/// The AskUserQuestion input that Claude Code 2.1.330 sent to a
/// `PermissionRequest` hook in the live probe (two questions, the second
/// multiple-choice). Descriptions shortened.
private var questionInput: [String: Any] { [
    "questions": [
        [
            "question": "Which color do you prefer?", "header": "Color", "multiSelect": false,
            "options": [
                ["label": "Red", "description": "Choose Red"],
                ["label": "Blue", "description": "Choose Blue"],
                ["label": "Green", "description": "Choose Green"],
            ],
        ],
        [
            "question": "Which fruits do you like?", "header": "Fruits", "multiSelect": true,
            "options": [
                ["label": "Apple", "description": "Choose Apple"],
                ["label": "Banana", "description": "Choose Banana"],
                ["label": "Cherry", "description": "Choose Cherry"],
            ],
        ],
    ]
] }

private var suggestion: [String: Any] { [
    "type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test"]],
    "behavior": "allow", "destination": "localSettings",
] }

private func payload(
    tool: String, input: [String: Any], suggestions: [Any]? = nil
) throws -> Data {
    var object: [String: Any] = [
        "session_id": "s1", "hook_event_name": "PermissionRequest", "cwd": "/repo",
        "permission_mode": "default", "tool_name": tool, "tool_input": input,
    ]
    if let suggestions { object["permission_suggestions"] = suggestions }
    return try JSONSerialization.data(withJSONObject: object)
}

/// The helper side of one request: the event as the answer mode builds it,
/// and what it keeps in memory.
private func helperRequest(
    tool: String, input: [String: Any], suggestions: [Any]? = nil
) throws -> (event: AgentHookEvent, request: ClaudeAnswerModeRequest) {
    let data = try payload(tool: tool, input: input, suggestions: suggestions)
    let event = try AgentHookEvent(provider: .claude, payload: data, includesRequestSummary: true)
    return (event, try #require(ClaudeAnswerModeRequest(event: event, payload: data)))
}

private func decision(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
    #expect(specific["hookEventName"] as? String == "PermissionRequest")
    return try #require(specific["decision"] as? [String: Any])
}

private func answered(_ answer: AgentPermissionAnswer) -> AgentAnswerOutcome {
    .answered(answer)
}

@Suite("Claude answer mode request")
struct ClaudeAnswerModeRequestTests {
    @Test("A question set round-trips: spool, answer file, helper output")
    func questionSetRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rafu-answer-mode-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = root.appending(path: "AgentTracking/spool", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        let channel = AgentAnswerChannel(spool: spool)

        // Helper: build the event, keep the input, spool the event.
        let (event, request) = try helperRequest(tool: "AskUserQuestion", input: questionInput)
        #expect(request.classification == .questions)
        #expect(request.waitsForAnswer)
        try AgentHookSpool.write(event, to: spool)

        // App: drain, read the questions, write the answer by index.
        let drained = try #require(try AgentHookSpool.drain(directory: spool).first)
        let summary = try #require(drained.requestSummary)
        #expect(summary.questions.map(\.id) == ["0", "1"])
        #expect(summary.questions.map(\.allowsMultiple) == [false, true])
        try channel.write(
            AgentPermissionAnswer(
                eventID: drained.id, verdict: .allow,
                answers: [
                    .init(index: 0, labels: ["Green"]),
                    .init(index: 1, labels: ["Apple", "Banana"]),
                ]))

        // Helper: wait, then print updatedInput with the answers.
        let outcome = channel.wait(eventID: event.id, timeout: 1, isWatched: { true })
        let printed = try decision(request.output(for: outcome))
        #expect(printed["behavior"] as? String == "allow")
        let updated = try #require(printed["updatedInput"] as? [String: Any])
        #expect(
            updated["answers"] as? [String: String] == [
                "Which color do you prefer?": "Green",
                "Which fruits do you like?": "Apple, Banana",
            ])
        // The original questions go back unchanged.
        let original = try JSONSerialization.data(
            withJSONObject: questionInput["questions"] as Any, options: .sortedKeys)
        let echoed = try JSONSerialization.data(
            withJSONObject: updated["questions"] as Any, options: .sortedKeys)
        #expect(original == echoed)
    }

    @Test("Free text is the value; labels and text of a multiple choice are joined")
    func freeText() throws {
        let (event, request) = try helperRequest(tool: "AskUserQuestion", input: questionInput)
        let answer = AgentPermissionAnswer(
            eventID: event.id, verdict: .allow,
            answers: [
                .init(index: 0, labels: [], text: "Purple with a hint of teal"),
                .init(index: 1, labels: ["Cherry"], text: "Mango"),
            ])
        let updated = try #require(
            try decision(request.output(for: answered(answer)))["updatedInput"]
                as? [String: Any])
        #expect(
            updated["answers"] as? [String: String] == [
                "Which color do you prefer?": "Purple with a hint of teal",
                "Which fruits do you like?": "Cherry, Mango",
            ])
    }

    @Test("An answer that does not match the kept questions prints nothing")
    func mismatch() throws {
        let (event, request) = try helperRequest(tool: "AskUserQuestion", input: questionInput)
        func output(_ answers: [AgentPermissionAnswer.QuestionAnswer]) -> Data? {
            request.output(
                for: answered(.init(eventID: event.id, verdict: .allow, answers: answers)))
        }
        // A label that is not a choice.
        #expect(output([.init(index: 0, labels: ["Pink"]), .init(index: 1, labels: ["Apple"])])
            == nil)
        // Two labels on a single-choice question.
        #expect(
            output([.init(index: 0, labels: ["Red", "Blue"]), .init(index: 1, labels: ["Apple"])])
                == nil)
        // One question left out, or an index out of range.
        #expect(output([.init(index: 0, labels: ["Red"])]) == nil)
        #expect(output([.init(index: 0, labels: ["Red"]), .init(index: 5, labels: ["Apple"])]) == nil)
    }

    @Test("A question set takes no plain allow; a deny prints")
    func questionVerdicts() throws {
        let (event, request) = try helperRequest(tool: "AskUserQuestion", input: questionInput)
        #expect(request.output(for: answered(.init(eventID: event.id, verdict: .allow))) == nil)
        let denied = try decision(
            request.output(for: answered(.init(eventID: event.id, verdict: .deny))))
        #expect(denied["behavior"] as? String == "deny")
        #expect(request.output(for: .dismissed) == nil)
        #expect(request.output(for: .timedOut) == nil)
        #expect(request.output(for: .unwatched) == nil)
    }

    @Test("Answers never reach a tool that is not a question set")
    func answersOnlyForQuestions() throws {
        // A built-in tool whose input happens to hold `questions`.
        let (event, request) = try helperRequest(tool: "WebSearch", input: questionInput)
        #expect(request.classification == .toolCall)
        #expect(request.waitsForAnswer)
        let answer = AgentPermissionAnswer(
            eventID: event.id, verdict: .allow,
            answers: [.init(index: 0, labels: ["Red"]), .init(index: 1, labels: ["Apple"])])
        #expect(request.output(for: answered(answer)) == nil)
        // A plain allow of the tool card prints a plain allow.
        let allowed = try decision(
            request.output(for: answered(.init(eventID: event.id, verdict: .allow))))
        #expect(Set(allowed.keys) == ["behavior"])
    }

    @Test("A plan and an unclassified request never wait and never print")
    func shownOnly() throws {
        let plan = try helperRequest(tool: "ExitPlanMode", input: ["plan": "## Plan"])
        #expect(plan.request.classification == .plan)
        #expect(!plan.request.waitsForAnswer)
        #expect(
            plan.request.output(for: answered(.init(eventID: plan.event.id, verdict: .allow)))
                == nil)
        let odd = try helperRequest(tool: "odd tool", input: ["x": 1])
        #expect(odd.request.classification == .unclassified)
        #expect(!odd.request.waitsForAnswer)
        #expect(
            odd.request.output(for: answered(.init(eventID: odd.event.id, verdict: .deny))) == nil)
    }

    @Test("Remember echoes the one suggestion only for a command or tool, and only by policy")
    func remember() throws {
        let bash = try helperRequest(
            tool: "Bash", input: ["command": "npm test"], suggestions: [suggestion])
        let answer = AgentPermissionAnswer(eventID: bash.event.id, verdict: .allow, remember: true)
        // Lasting grants are off: nothing prints, the terminal dialog stays.
        #expect(bash.request.output(for: answered(answer)) == nil)
        let granted = try decision(bash.request.output(for: answered(answer), policy: .all))
        #expect((granted["updatedPermissions"] as? [Any])?.count == 1)
        // Two suggestions: none is kept.
        let two = try helperRequest(
            tool: "Bash", input: ["command": "npm test"], suggestions: [suggestion, suggestion])
        #expect(
            two.request.output(
                for: answered(.init(eventID: two.event.id, verdict: .allow, remember: true)),
                policy: .all) == nil)
        // A file change never remembers.
        let write = try helperRequest(
            tool: "Write", input: ["file_path": "/r/a", "content": "x"], suggestions: [suggestion])
        #expect(
            write.request.output(
                for: answered(.init(eventID: write.event.id, verdict: .allow, remember: true)),
                policy: .all) == nil)
    }

    @Test("An event without a request summary keeps nothing")
    func noSummary() throws {
        let data = try payload(tool: "Bash", input: ["command": "ls"])
        let plain = try AgentHookEvent(provider: .claude, payload: data)
        #expect(ClaudeAnswerModeRequest(event: plain, payload: data) == nil)
    }
}
