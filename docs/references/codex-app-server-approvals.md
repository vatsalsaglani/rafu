# Answering Codex approvals and questions through the proxy

Applies to: `Sources/RafuCore/CanvasBridge/CanvasCodexProxy.swift` (the request table, `inject`, the upstream write
lock), `CanvasCodexApprovalSupervisor.swift` (open, poll and close calls to the app, the poll timer),
`CanvasCodexSession.swift` (wires the supervisor to the proxy), `CanvasAgentRequest.swift` (the sanitized request and
the reply shapes), and `Sources/RafuApp/Canvas/Integration/CanvasLiveBridge.swift` (the three bridge operations).
Tests: `Tests/RafuCoreTests/CanvasCodexApprovalTests.swift`.

Last verified: Swift 6.4.2, macOS 27, 2026-11-20, codex-cli 0.170.0 (live probes below, through the real proxy and
supervisor code, with the real `codex app-server` and a real `codex --remote` terminal UI in a pseudo-terminal). The sections dated 2026-11-21 use codex-cli 0.171.0: the
schema and binary strings were read, and the MCP tool approval section was not run live.

## Observations

1. **The server resolves a request on the connection that owns it, and any client may answer.** The terminal UI
   (TUI) gets a server request (`item/commandExecution/requestApproval`, `item/fileChange/requestApproval`,
   `item/permissions/requestApproval`, `item/tool/requestUserInput`; since 2026-11-21 also
   `mcpServer/elicitation/request`, see the section "MCP tool approvals are elicitations") with a JSON-RPC `id`. A
   response with that same `id` on the TUI's own connection answers it. The proxy writes one masked text frame
   `{"id": <same id>, "result": {...}}` upstream, as if the TUI had sent it.
2. **The TUI closes its own prompt.** After the injected answer the server sends `serverRequest/resolved`. The TUI
   dismisses its prompt on that notification, with no keystroke. Observed with a command approval: the prompt
   ("Would you like to run the following command?") was on screen, the injected `accept` went upstream, the prompt
   was gone about 5 s later (the supervisor poll delay chosen in the probe), the command ran, and the turn ended with
   "Ran touch ..." and "Done".
3. **A later TUI keypress is safe.** A second command approval in the same conversation was answered by pressing
   `y` in the TUI: the proxy saw the TUI's response, cleared the entry, the supervisor closed the row within 20 ms,
   and the command ran. No desync, no crash.
4. **The server only accepts the decision once.** A second response with the same `id` is ignored by the server
   (the unknown id). The proxy still removes the entry on the first inject, so a poll that keeps returning the same
   answer until `approvalClose` injects once.
5. **Approval policy values.** `approval_policy = "untrusted"` is refused by 0.170.0 ("is no longer supported").
   Use `on-request` with `sandbox_mode = "read-only"` on the app server to make the model ask before a command that
   writes. Server `-c` values apply to the whole app server, so they only fit a probe.

## Reply shapes

Each shape below was sent by the real proxy and supervisor code to the real `codex app-server`, with a real
`codex --remote` terminal UI on a pseudo-terminal (probe results, 2026-11-20).

| Request | Reply `result` | Observed |
|---|---|---|
| command | `{"decision": "accept"}` | Command ran. Prompt closed by itself. Turn finished ("Ran touch ...", "Done"). |
| command | `{"decision": "acceptForSession"}` | Command ran. Prompt closed. A second command with a different text asked again (the grant matches the command, not the session). |
| command | `{"decision": "decline"}` | Command did not run. Prompt closed. Codex said "Approval was rejected; the command did not run" and ended the turn in 12 s. |
| command | `{"decision": "cancel"}` | Command did not run. Prompt closed. The TUI showed "Conversation interrupted": the turn stopped. |
| permissions | accept: `{"permissions": <the requested profile>, "scope": "turn"}` | Prompt closed. Codex went on and asked for the shell command next (also accepted), and the command ran. |
| permissions | decline: `{"permissions": {}, "scope": "turn"}` | Prompt closed. The TUI treated it as "No, continue without permissions". The later command failed with "Operation not permitted". |
| questions | `{"answers": {"colour": {"answers": ["Blue"]}}}` | Question closed. The model answered "Blue". |

Not run live: a permissions reply with scope `session`, and the file change request. They follow the same schema.

Rafu does not answer a file change request from Up next: it is always terminal-only, because its params carry no
diff and the row cannot show the change. A command request that carries `networkApprovalContext` is terminal-only
too (the row does not show the host). See the decision record "Answer agent requests from the Up next row"
([`0042-answer-agent-requests-from-up-next.md`](../decisions/0042-answer-agent-requests-from-up-next.md)).

## Codex marks every model question `isOther`

`item/tool/requestUserInput` arrives with `isOther: true` for the question the model asks. The TUI shows it as a
third row, "None of the above (add details in notes)". A labelled option is still a valid answer. An early contract
made a question terminal-only when `isOther` was set. Then every Codex question was terminal-only and the Up next row
could not answer any. A local probe with the `isOther` term removed from that condition showed the request was
answerable and the labelled answer worked. Decision (2026-11-20): `isOther` alone does not make a question
terminal-only (`CanvasAgentRequest.Question.init`, test in `CanvasAgentRequestTests`). The row shows only the labelled
options. A free-text answer still needs the terminal.

## The diff of a file change comes from `patchUpdated` (2026-11-21, codex-cli 0.171.0)

Applies to: `CanvasAgentRequest.fileChanges(fromPatchUpdated:)`, the patch cache in `CanvasCodexProxy.Connection`
(`notePatch`, `patch(itemID:)`). Tests: `CanvasCodexApprovalTests` (`patchUpdatedFillsTheFileChangeRequest`,
`aFileChangeWithoutAPatchStaysTerminalOnly`, `thePatchCacheClearsWhenTheTurnEnds`,
`thePatchCacheKeepsAtMostEightItems`) and `CanvasAgentRequestTests` (`patchUpdatedMapping`).

- `FileChangeRequestApprovalParams` has only `itemId`, `threadId`, `turnId`, `startedAtMs`, and optional `reason`
  and `grantRoot`. It carries no diff.
- The diff arrives in the notification `item/fileChange/patchUpdated` (`FileChangePatchUpdatedNotification`):
  `itemId`, `threadId`, `turnId` and `changes`, a list of `{path, diff, kind}`. `kind` is an object:
  `{"type": "add"}`, `{"type": "delete"}` or `{"type": "update", "move_path": <string or null>}`.
- Rafu keeps the newest patch of each `itemId` (at most 8 per connection), clears them on `turn/completed` for the
  bound thread and when the connection retires, and never logs them. A later request for that `itemId` is
  answerable only when the patch fits the bounds exactly (at most 2 files, 4 KiB of diff each); no patch, or a
  `kind` that Rafu does not know, makes the request terminal-only.
- The order is an assumption that was not verified live: the patch notification comes before the approval request
  of the same item. If it does not, the request is terminal-only (the safe result).
- "Allow for this session" stays off for file changes. Whether a Codex session grant for files would apply to the
  same `grantRoot` was not verified.

Reproduce the schema: `codex app-server generate-json-schema --out <dir>`, then read
`FileChangeRequestApprovalParams.json` and the `FileChangePatchUpdatedNotification` and `PatchChangeKind` entries of
`codex_app_server_protocol.v2.schemas.json`.

## Rules

- **The JSON-RPC id never leaves the proxy.** The table maps an opaque key (a UUID) to the raw id text. The app,
  the supervisor and every log see only the key.
- **No request or answer text in any log.** Not the command, the reason, the question, the profile or the decision.
- **One write lock per connection** (`upstreamWrite`) serializes every frame toward the server. The outgoing relay
  takes it for each upstream write, and `inject` takes it for its one frame. The lock also holds the "inside a
  fragmented message" flag, so an injected frame never lands between two fragments of a data message.
  `inject` refuses with `.busy` there and the supervisor retries on the next poll.
- **`inject` outcomes.** `.sent` (entry removed, frame written), `.unknown` (no such key on the active, live
  connection), `.refused` (the decision does not fit the request, or the write failed and the connection was
  retired), `.busy` (fragmented). Every outcome except `.busy` ends with `approvalClose`, because the app keeps its
  answer until closed.
- **The descriptors stay open during an inject.** An inject takes a hold on the connection (it counts like a worker),
  so a close cannot reuse the descriptor number under a write.
- **What clears an entry**: the TUI's own response with that id (outgoing, no method); `serverRequest/resolved` for
  the bound thread; `turn/completed` for the bound thread (clears every entry); the connection retiring (end,
  replacement, `stop()`, a failed write). Each sends `approvalClose` once.
- **Bounds**: at most 8 tracked requests per connection. A ninth is forwarded to the TUI as usual and is not announced
  (the user answers it in the terminal). Only requests whose `params.threadId` equals the bound thread are tracked;
  an unbound session tracks nothing.
- **One serial queue for all app calls.** An open and the close for the same key can never swap places. The relay
  threads only enqueue; they never wait for the app. The proxy announces a request before it forwards the frame to
  the TUI, so the supervisor always hears "open" before it can hear the TUI's own answer ("clear").
- **Permissions**: the table keeps `params.permissions` (as JSON) because an accepted request must send exactly that
  profile back. A request without it cannot be accepted.

## Reproduce

The probe was a temporary test that started `codex app-server --listen unix://<dir>/socket -c
approval_policy="on-request" -c sandbox_mode="read-only"`, made a thread with `CanvasCodexRPC.createThread`, put a
`CanvasCodexProxy` and a `CanvasCodexApprovalSupervisor` in front of it, and used a stand-in for the app that answered
the first poll after 5 s. The terminal UI ran as `codex --remote unix://<dir>/terminal resume <thread>` in a pseudo-terminal
(Python `pty` and the `pyte` screen model, installed into a scratch folder). The prompt asked the model to run
`touch <file>` and to ask for approval. Question probe: `--enable default_mode_request_user_input` on the server.
Permission probe: `--enable request_permissions_tool --enable exec_permission_approvals`. Each probe left one named
session in `~/.codex`; archive it with the `thread/archive` request.

## Rafu's own MCP tools are pre-approved (2026-11-21, codex-cli 0.171.0)

Codex asks "Allow the rafu MCP server to run tool "ensemble_describe"?" for each Rafu tool. That question is an MCP
elicitation (`mcpServer/elicitation/request` in the 0.171.0 method table). Until 2026-11-21 the proxy tracked four
request methods only, so this one never showed in Up next; it showed in the terminal as "Needs you · Answer in the
terminal" (an agent hook state), and the user had decided not to add Up next support for other servers' approvals.
That decision was reversed for tool approvals the same day: see the next section.

For Rafu's own server the question is redundant: Agent control (Off, Ask, Allow) already decides every call. The
launcher adds `-c mcp_servers.rafu.default_tools_approval_mode="approve"` to the terminal's private app server
(`CanvasBridgeLaunch.plan`; it sits in the prefix that `run` drops with `dropLast(arguments.count)`). It never writes
`~/.codex/config.toml`, and it names only the `rafu` server. Decision:
[`0044-pre-approve-rafu-tools-for-codex.md`](../decisions/0044-pre-approve-rafu-tools-for-codex.md).

Verified values (0.171.0): the setting accepts `auto`, `prompt`, `writes` and `approve`. A per-tool form,
`mcp_servers.<name>.tools.<tool>.approval_mode`, also exists. Reproduce (no write to the user's Codex config; the
`-c` flags apply to this one command):

```bash
codex -c mcp_servers.zzz.command="/bin/true" \
  -c mcp_servers.zzz.default_tools_approval_mode="bogus" mcp list
# Error: unknown variant `bogus`, expected one of `auto`, `prompt`, `writes`, `approve`
codex -c mcp_servers.zzz.command="/bin/true" \
  -c mcp_servers.zzz.default_tools_approval_mode="approve" mcp list   # loads and lists "zzz"
```

Not verified: that `approve` removes the question in a live Codex turn. If it still prompts, try `writes` (the Rafu
tool list marks read-only tools with `readOnlyHint`), then the per-tool `approval_mode`. Note: inside a Rafu terminal
the `codex` on `PATH` is Rafu's wrapper, so run the probe with the real binary path.

Claude Code's equivalent of this approval mode is `--allowedTools=mcp__rafu` (see the notification section of
[`claude-permission-request-hook.md`](claude-permission-request-hook.md) and the amendment in the decision record about
pre-approving Rafu's tool server).

## MCP tool approvals are elicitations (2026-11-21, codex-cli 0.171.0; schema only, not run live)

Applies to: `CanvasAgentRequest.parse` (case `mcpServer/elicitation/request`, helper `toolCallRequest`, set
`knownToolApprovalMetaKeys`), `CanvasAgentRequest.result(for:)` (case `.toolCall`), `approvalMethods` in
`CanvasCodexProxy.swift`. Tests: `CanvasAgentRequestTests`, `CanvasCodexApprovalTests`. Decision records: the amendment
"Codex requests for MCP tools answer in the peek" of
[`0042-answer-agent-requests-from-up-next.md`](../decisions/0042-answer-agent-requests-from-up-next.md) and decision 5 of
[`0044-pre-approve-rafu-tools-for-codex.md`](../decisions/0044-pre-approve-rafu-tools-for-codex.md) (reversed for tool
approvals).

**Update 2026-11-22:** the INFERRED `_meta` key list and the answer table below are replaced by the next section
("Every server request shows"), which is checked against the Codex source at the tag `rust-v0.171.0`. Read the next
section first.

Codex asks before it calls a tool of an MCP server (for example "Allow the atlassian MCP server to run tool
"getJiraIssue"?") with the server request `mcpServer/elicitation/request`. The proxy now follows it. A tool approval
opens the same `toolCall` request that a Claude MCP tool request uses ("Use MCP tool" card).

**Verified from the generated schema (0.171.0):**

- Params: `threadId`, `turnId` (string or null), `serverName`, `environmentId`, `mode`, `message`, `_meta`.
  `mode` is `form` (with `requestedSchema`, an object with `properties`), `openai/form`, `openaiForm` or `url`
  (with `url` and `elicitationId`).
- Response: `{"action": "accept" | "decline" | "cancel", "content": <any JSON or null>, "_meta": <any JSON or
  null>}`. Only `action` is required.
- `serverRequest/resolved` (`{threadId, requestId}`) clears the request, as for the other methods. There is no
  "accept for session" decision on this method.

**INFERRED from strings in the Mach-O binary (`strings`), not in the schema and not seen on a live request:** the
`_meta` of a tool approval holds `codex_approval_kind` = `mcp_tool_call`, `tool_name`, `tool_params` (an object), and
probably `tool_params_display`, `tool_title`, `tool_description`, `source`, `connector_id`, `connector_name`,
`connector_description`, `persist`, `codex_request_type`. The evidence is the automatic reviewer's error texts ("must
declare mcp_tool_call approval kind", "must include a non-empty tool_name", "tool_params must be an object", "review
only supports empty form schemas", "review only supports form elicitations"). The terminal UI offers "remember for this
session" and "remember for future tool calls"; these are `accept` plus a `persist` value in the response `_meta`.
Other `_meta` keys exist in the binary that Rafu does not understand: `codex_sensitive_action`,
`codex_requires_user_input`, `codex_approval_cancellation_reason`.

**Recognition rule (all must hold, else no row and the terminal answers, as before):** mode `form`; `requestedSchema`
an object whose `properties` is absent, null or empty; `_meta` an object with `codex_approval_kind` equal to
`mcp_tool_call`; `serverName` non-empty and without `__`; `_meta.tool_name` non-empty; `_meta.tool_params` a JSON
object (an empty object is valid; absent, null or another type gives no row, because Rafu must not let the user
approve arguments it did not show); the built name `mcp__<server>__<tool>` passes the Claude name rule
(`AgentPermissionRequestSummary.mcpParts`: characters `A-Z a-z 0-9 _ - .`, at most 200 bytes) and splits back into the
same server and tool. A `_meta` key outside `knownToolApprovalMetaKeys` (for example `codex_sensitive_action`) makes
the row terminal-only ("Open terminal"), because the request may ask for more than the card shows. An incomplete
summary (arguments over 2 KiB, or cut or changed by the sanitizer) is terminal-only too. Rafu never reads `message`,
`tool_title`, `tool_params_display` or the connector fields. A generic form (a property in the schema) and a `url`
elicitation are forwarded to the terminal and not announced.

**Answers (not run live):**

| Button | Decision | `result` sent upstream |
|---|---|---|
| Allow | accept | `{"action": "accept", "content": {}}` |
| Deny | decline | `{"action": "decline"}` |
| Deny and stop | cancel | `{"action": "cancel"}` |

Rafu never sends `_meta`, so it never sends `persist`: no "remember" answer can come from Rafu, and "Allow for this
session" stays off for this kind. A Claude tool call never reaches the proxy table, so changing `result(for:)` for
`.toolCall` cannot change a Claude answer.

**Not verified. Hand checks (they need a live Codex turn and one MCP server in the user's Codex config that is not
`rafu`; run the real binary, not Rafu's wrapper):**

1. The exact `_meta` keys of a live request. If no card shows, or the card says "Open terminal" only, capture one
   real request and compare key names (never values) with the rule. Do not loosen the rule without a captured frame.
2. That `{"action":"accept","content":{}}` runs the tool (`content` may need to be `null` or another shape).
3. That the terminal prompt closes by itself on `serverRequest/resolved` for this method (proved only for a command
   approval, observation 2).
4. That `cancel` stops the turn. For a command approval it does ("Conversation interrupted"). For an MCP tool it may
   only skip the call; then "Deny and stop" is a false label for Codex, and the fallback is Allow and Deny only for a
   Codex tool call, with a new stored flag on the request (needs the user's decision).
5. That a Rafu tool (`ensemble_describe`) raises no Codex question (this also proves the `approve` setting above).

Reproduce the schema: `codex app-server generate-json-schema --out <dir>` (and `generate-ts --out <dir>`), then read
`McpServerElicitationRequestParams.json` and `McpServerElicitationRequestResponse.json`. The `_meta` keys were found
with `strings` on the `codex` binary.

## Every server request shows; the tool card key set (2026-11-22, Codex 0.171.0, source tag `rust-v0.171.0`)

Applies to: `CanvasAgentRequest.parseCodex`, `classify(method:)`, `knownToolApprovalMetaKeys`,
`forcingToolApprovalMetaKeys`, `toolCallRequest(fromElicitation:)`, `result(for:)`, `stopsTurnOnCancel`, and
`trackApprovals` in `CanvasCodexProxy.swift`. Tests: `CanvasAgentRequestTests`, `CanvasCodexApprovalTests`,
`AgentPromptCoverageTests`. The prompt inventory and the version checklist:
[`agent-prompt-coverage.md`](agent-prompt-coverage.md). Decision record: the amendment "Every agent prompt shows;
question sets answer in Rafu" in [`0042-answer-agent-requests-from-up-next.md`](../decisions/0042-answer-agent-requests-from-up-next.md).

**Live symptom (2026-11-22).** A Google Calendar tool of the `codex_apps` server showed a card with "Open terminal"
only.

**Root cause (checked in the source).** The `_meta` key list of the first version was inferred from binary strings.
It missed three keys that Codex 0.171.0 does send: `tool_annotations`, `link_id` and `link_is_implicit`. A
`codex_apps` connector tool carries all three, so the card became terminal-only. The list also held
`codex_request_type`, which the builder does not write (it was inferred and is removed).

The keys that `build_mcp_tool_approval_elicitation_meta` (`codex-rs/core/src/mcp_tool_call.rs`) can write, now the
known set: `codex_approval_kind`, `persist`, `tool_name`, `tool_annotations`, `tool_title`, `tool_description`,
`source`, `connector_id`, `link_id`, `link_is_implicit`, `connector_name`, `connector_description`, `tool_params`,
`tool_params_display`.

Four keys keep the request terminal-only, whatever their value, because they change what an approval means
(`codex-rs/protocol/src/mcp_approval_meta.rs`): `codex_sensitive_action`, `codex_requires_user_input`,
`codex_strict_auto_review`, `approvals_reviewer`. Any other unknown key also makes it terminal-only, and the shape
recorder names the key.

**`persist`** is absent, the string `"session"` or `"always"`, or the array of both. It decides which remember
choices Codex offers. Rafu models them, but `PersistPolicy.current` keeps both off (pending the user's decision), so
no `persist` goes out today.

**Answers** (source: `submit_answers` and `parse_mcp_tool_approval_elicitation_response` in
`codex-rs/tui/src/bottom_pane/mcp_server_elicitation.rs`). Not run live.

| Rafu button | `result` sent upstream |
|---|---|
| Allow | `{"action":"accept","content":null}` (an empty object `{}` also gives "Approved") |
| Allow for this session (off) | `{"action":"accept","content":null,"_meta":{"persist":"session"}}` |
| Always allow (off) | `{"action":"accept","content":null,"_meta":{"persist":"always"}}` |
| Cancel tool call | `{"action":"cancel","content":null,"_meta":{"codex_approval_cancellation_reason":"user"}}` |
| Deny | `{"action":"decline"}`: the model reads "user rejected MCP tool call" |

`cancel` does not stop the turn: core tells the model "user cancelled MCP tool call" and goes on. So a Codex tool
call shows "Cancel tool call" and not "Deny and stop" (`stopsTurnOnCancel` is false for it; a command still says "Deny
and stop", because `cancel` stops the turn there, see the reply table).

**Not known from the source:** whether the app-server adds a key to `_meta` on the way out. The shape recorder shows
the answer on the first real request. Hand check: ask a Codex terminal in Rafu Lightning to create a calendar event
(any connector tool). If the card still shows only "Open terminal", run
`log show --last 10m --predicate 'category == "AgentRequestShape"' --info` and read the key names.

**Every server request for the thread is parsed.** A method that is a prompt but that Rafu does not answer gives a
`notice` row and a recorded shape, not nothing. Only `item/tool/call`, token refresh and attestation give no row.
The thread match reads `params.threadId`, and the older approval methods (`applyPatchApproval`,
`execCommandApproval`) name it in `params.conversationId`. A generic MCP form, a message-only approval, a URL
elicitation (`browser_auth`, `tool_suggestion`) and an old-API approval show read-only with the server's own
message. Whether the 0.171.0 terminal still sends the old methods is not known; the recorder shows it.

**Tool approval sent as a question.** When the Codex feature `ToolCallMcpElicitation` is off, Codex sends the
approval as a `request_user_input` question whose id starts with `mcp_tool_call_approval`. The request holds no
tool arguments, so Rafu could not show what would run. It shows a terminal-only notice ("Tool approval: open the
terminal to see the arguments").

**Questions.** `request_user_input` has 1 to 3 questions, each with `id`, `header`, `question`, and `options`
(`label`, `description`); `isOther` is always true, `isSecret` can be set, and there is no multi-select (source:
`codex-rs/core/src/tools/handlers/request_user_input_spec.rs`). Free text is now answerable: the result is
`{"answers": {"<id>": {"answers": ["<label>", "user_note: <text>"]}}}`. With a text and no chosen label the list is
`["None of the above", "user_note: <text>"]`, the label Codex adds for its "other" row. A secret question stays
terminal-only.

**Commands.** A network approval (`networkApprovalContext`) now shows "Network: <protocol> <host>" and can be
accepted, declined or cancelled, with no session answer (it was terminal-only). A `proposedExecpolicyAmendment` that
is a list of at most 16 plain words within 256 bytes becomes the remember choice "Always allow commands that start
with <words>" (`{"decision":{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":[...]}}}`); it is off under
`PersistPolicy.current`. Codex schema facts are checked; none of these were run live.

Reproduce the source reading: the tag `rust-v0.171.0` of the Codex repository, the four files named above.

Test evidence: the Codex group's parallel run passed in its worktree; the count was not supplied to the documentor.
Coordinator runs on `main`: Coordinator on `main` (2026-11-22, after the merge of the Needs-you hint follow-up): `./script/test.sh` and `./script/test.sh --no-parallel` both passed (4,174 tests in 339 suites and 795 tests in 54 suites); `./script/build_and_run.sh --verify` passed. Hand tests in Rafu Lightning are open.

## Verification

```bash
swift test --filter CanvasCodexApprovalTests
swift test --filter CanvasAgentRequestTests
swift test --filter CanvasBridgeLaunchTests
```

Test evidence for the elicitation change: 4143 tests passed in parallel mode in the implementor's worktree. The
`--no-parallel` count was not supplied to the documentor.

## Related

- Decision: [`0042-answer-agent-requests-from-up-next.md`](../decisions/0042-answer-agent-requests-from-up-next.md)
  (answer on the agent's own channel; the terminal stays in charge).
- [`claude-permission-request-hook.md`](claude-permission-request-hook.md): the Claude Code side of the same path.
- [`notch-companion.md`](notch-companion.md): the approval rows that show these requests.
