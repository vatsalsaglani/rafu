# Agent prompt coverage and the version checklist

- Applies to: every prompt that Claude Code or Codex can show a person, and how Rafu shows it. Code:
  `Sources/RafuCore/AgentTracking/AgentPermissionRequestSummary.swift` (`Classification`,
  `classification(forToolName:)`), `Sources/RafuCore/CanvasBridge/CanvasAgentRequest.swift` (`CodexRequestClass`,
  `classify(method:)`, `parseCodex`, `knownToolApprovalMetaKeys`, `forcingToolApprovalMetaKeys`),
  `Sources/RafuCore/AgentTracking/AgentRequestShape.swift` (the recorder), `AgentHookEvent.swift` (`requestShape`).
  Tests: `Tests/RafuCoreTests/AgentPromptCoverageTests.swift`, `AgentRequestShapeTests.swift`.
- Last verified: Claude Code 2.1.330 and Codex CLI 0.171.0, 2026-11-22. The Swift and macOS versions were not
  stated in the handoff.

## Rule or observed behavior

**Nothing returns nil in silence.** Three silent allow-lists caused the same gap again and again:

1. `AgentPermissionRequestSummary.init?` returned nil for every Claude tool that was not Bash, Edit, MultiEdit,
   Write or an MCP tool. The helper then exited before it wrote the event. The user saw only "Needs you · Answer
   in the terminal".
2. `CanvasAgentRequest.parse` returned nil for a Codex method it did not know. It also made a tool approval
   terminal-only for any `_meta` key outside a list that was INFERRED from binary strings.
3. The plain row had one fixed text. It showed no question, no option and no reason.

Each earlier fix added one name to one list. The fix now is structural:

- A prompt that Rafu does not know shows read-only, with the agent's own text and "Open terminal" (request kind
  `notice`). Only a method that is not a prompt for the user returns no request (`CodexRequestClass.notUserPrompt`:
  `item/tool/call`, token refresh, attestation).
- Rafu records the shape of what it could not fully show. A shape has key names and value types only, never a value.
  So the next gap is found by Rafu, not by the user.
- `AgentPromptCoverageTests` fails when a Claude Code tool name or a Codex server request method has no class.

### The shape recorder

`AgentRequestShape.describe` gives one line: the name, the sorted key names of the first two levels, and the JSON
type of each value (`string`, `number`, `bool`, `array[n]`, `object`, `null`). Rules that keep values out
(`AgentRequestShapeTests` feeds a secret as a value and checks that it never appears):

- Key names show only when the agent's own code fixes them: a Claude Code built-in tool, a Codex `params` object.
  The input of an MCP tool shows counts per type only, because the server picks the names.
- A key name outside `[A-Za-z0-9_.-]`, or over 64 bytes, shows as `?`. The value of a key named `properties` shows
  as `object[n]`.
- A line is at most 512 bytes (longer ends in an ellipsis).
- The recorder logs one line for each distinct shape for each launch, at most 64 shapes, at `notice` level with
  public privacy. The logger category is `AgentRequestShape`.

When Rafu records a shape: a Claude request that is `unclassified` (the helper puts the line in the spooled event
field `requestShape`; the app logs it), a Codex request that becomes a notice, and a Codex tool approval that is
terminal-only because of an unknown `_meta` key.

Read it:

```bash
log show --last 1h --predicate 'category == "AgentRequestShape"' --info
```

## The living table

"Answer" means a user can answer from the Up next row or the approval peek. "Card" means the request shows whole.
Unit tests cover every row. Live runs are named where they exist.

| Agent | Prompt | What Rafu shows | Answer from Rafu |
|---|---|---|---|
| Claude | Bash | Command card | Yes (live, earlier work) |
| Claude | Edit, MultiEdit, Write | Card with the change | Yes (live, earlier work) |
| Claude | MCP tool `mcp__server__tool` | "Use MCP tool" card | Yes |
| Claude | Any other tool in the tools table (Read, Glob, Grep outside the folders, WebFetch, WebSearch, NotebookEdit, Skill, Agent, Workflow, ...) | Generic tool card: "Claude Code tool: <name>", the whole `tool_input` as sorted JSON | Yes (unit tests only) |
| Claude | `AskUserQuestion` (1 to 4 questions) | Question set | Yes (live probe P1) |
| Claude | `ExitPlanMode` | "Plan ready" card, read-only | No: payload for the three plan choices unknown |
| Claude | Unknown tool name or an input that is not an object | Notice "Claude Code asks to use <name>" | No |
| Claude | Sandboxed command network request | Notice with the notification text | No: no `PermissionRequest` hook runs (docs) |
| Claude | MCP elicitation form or link | Notice with the notification text | No (parked) |
| Claude | "Chat about this" | Not seen | No (parked) |
| Claude | Folder trust, login, `/permissions`, model switch | The notification text on the "Needs you" row, when there is one | No hook can answer |
| Codex | Command approval | Command card, with the host of a network approval | Yes. Network: no session answer |
| Codex | File change approval | Card with the diff from `item/fileChange/patchUpdated` | Yes |
| Codex | Extra permissions | Card | Yes |
| Codex | `request_user_input` (1 to 3 questions) | Question set, free text allowed | Yes |
| Codex | MCP tool approval (`mcpServer/elicitation/request`, kind `mcp_tool_call`) | "Use MCP tool" card | Yes (source checked, not run live) |
| Codex | Tool approval sent as a question (id prefix `mcp_tool_call_approval`) | Terminal-only notice: the request holds no arguments | No |
| Codex | Generic MCP form, message-only approval, URL, `browser_auth`, `tool_suggestion` | Notice with the server's message | No (parked) |
| Codex | `applyPatchApproval`, `execCommandApproval` (old API) | Notice | No (parked; the recorder shows whether 0.171.0 sends them) |
| Codex | Any method Rafu does not know | Notice named with the last word of the method, and a recorded shape | No |
| Codex | `item/tool/call`, token refresh, attestation | Nothing (not prompts for the user) | Not applicable |
| Codex | "Implement this plan?" | Not seen. INFERRED: a prompt of the terminal UI, not a server request | No (parked) |

Remember choices (Codex session and always, a command prefix rule, a Claude permission rule) are built but off. See
the pending amendment in the decision record about answering agent requests from the Up next row (ADR 0042).

## The version checklist

Run this on every Claude Code or Codex update. Each step names a file to change.

1. **Codex schema.** Run `codex app-server generate-ts --out <dir>`. Use the real binary, not Rafu's wrapper. Then:

   ```bash
   RAFU_CODEX_SCHEMA_DIR=<dir> swift test --filter AgentPromptCoverage
   ```

   The folder must hold `ServerRequest.ts`. The test fails on a method that the fixture lacks. Add the method to
   `codexServerRequestMethods` in `AgentPromptCoverageTests.swift`, give it a class in
   `CanvasAgentRequest.classify(method:)`, and update `codexVersion` and the count (10 for 0.171.0).
2. **Claude Code tools.** Fetch the tools table of the Claude Code tools reference
   (`https://code.claude.com/docs/en/tools-reference.md`) and compare it with `claudeToolNames`. Update the list,
   `claudeVersion` and the count (53 for 2.1.330). A new name that is not in the strict built-in form gets
   `unclassified` and shows as a notice, which is safe.
3. **Claude hooks.** Read the hooks reference for new `PermissionRequest` input keys, new `Notification` types
   (see "Claude Code notification types and "Needs you"" in
   [`claude-permission-request-hook.md`](claude-permission-request-hook.md)) and a changed `updatedInput` rule.
4. **Codex `_meta` keys.** At the new tag, read `build_mcp_tool_approval_elicitation_meta`
   (`codex-rs/core/src/mcp_tool_call.rs`) and `codex-rs/protocol/src/mcp_approval_meta.rs`. Compare them with
   `knownToolApprovalMetaKeys` and `forcingToolApprovalMetaKeys`. Never add a key from binary strings alone.
5. **Codex answer shapes.** Read `submit_answers` and `parse_mcp_tool_approval_elicitation_response`
   (`codex-rs/tui/src/bottom_pane/mcp_server_elicitation.rs`) and `request_user_input/mod.rs`. Compare them with
   `CanvasAgentRequest.result(for:)`.
6. **Run a live session** with one of each prompt in the hand-test matrix of the Ensemble phase document, then read
   the recorder log (command above). A line there is a gap. Close it with a class, a card or a notice, and add a
   fixture name.
7. **Stamp the versions** in this note and in the two protocol notes.

## Why it matters

A prompt that Rafu drops makes the agent wait with nothing on screen but "Needs you". The user then learns that
Rafu cannot be trusted to show every question. Showing the prompt read-only costs little, and the recorded shape
turns each future gap into one log line.

## Reproduction or evidence

- Root cause: the three silent allow-lists above, read in the source at the base commit before this work.
- Live case: a Google Calendar tool of the Codex `codex_apps` server showed only "Open terminal" (2026-11-22). The
  cause is in [`codex-app-server-approvals.md`](codex-app-server-approvals.md).
- Fixtures: 53 Claude Code tool names (tools reference fetched 2026-11-22) and 10 Codex server request methods
  (schema of 0.171.0).

## Verification

```bash
swift test --filter "AgentPromptCoverage|AgentRequestShape"
RAFU_CODEX_SCHEMA_DIR=<dir with ServerRequest.ts> swift test --filter AgentPromptCoverage
```

Each implementation group passed its parallel run in its own worktree. The counts were not supplied to the
documentor. Coordinator runs on `main`: Coordinator on `main` (2026-11-22, after the merge of the Needs-you hint follow-up): `./script/test.sh` and `./script/test.sh --no-parallel` both passed (4,174 tests in 339 suites and 795 tests in 54 suites); `./script/build_and_run.sh --verify` passed. Hand tests in Rafu Lightning are open.

## Related code, ADRs, and phases

- [`claude-permission-request-hook.md`](claude-permission-request-hook.md): the Claude Code side.
- [`codex-app-server-approvals.md`](codex-app-server-approvals.md): the Codex side.
- [`notch-companion.md`](notch-companion.md): rule 21, the cards.
- Decision: [`0042-answer-agent-requests-from-up-next.md`](../decisions/0042-answer-agent-requests-from-up-next.md),
  amendment "Every agent prompt shows; question sets answer in Rafu".
- Phase: [`ensemble-canvas.md`](../plans/phases/ensemble-canvas.md), status 2026-11-22 and the hand-test matrix.
