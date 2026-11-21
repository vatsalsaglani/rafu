# Answering Codex approvals and questions through the proxy

Applies to: `Sources/RafuCore/CanvasBridge/CanvasCodexProxy.swift` (the request table, `inject`, the upstream write
lock), `CanvasCodexApprovalSupervisor.swift` (open, poll and close calls to the app, the poll timer),
`CanvasCodexSession.swift` (wires the supervisor to the proxy), `CanvasAgentRequest.swift` (the sanitized request and
the reply shapes), and `Sources/RafuApp/Canvas/Integration/CanvasLiveBridge.swift` (the three bridge operations).
Tests: `Tests/RafuCoreTests/CanvasCodexApprovalTests.swift`.

Last verified: Swift 6.4.2, macOS 27, 2026-11-20, codex-cli 0.170.0 (live probes below, through the real proxy and
supervisor code, with the real `codex app-server` and a real `codex --remote` terminal UI in a pseudo-terminal).

## Observations

1. **The server resolves a request on the connection that owns it, and any client may answer.** The terminal UI
   (TUI) gets a server request (`item/commandExecution/requestApproval`, `item/fileChange/requestApproval`,
   `item/permissions/requestApproval`, `item/tool/requestUserInput`) with a JSON-RPC `id`. A response with that same
   `id` on the TUI's own connection answers it. The proxy writes one masked text frame
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
elicitation (`mcpServer/elicitation/request` in the 0.171.0 method table). The proxy tracks four request methods only
(command, file change, permissions, question), so this one is not announced and never shows in Up next. It shows
in the terminal as "Needs you · Answer in the terminal" (an agent hook state). Rafu does not add Up next support for
other servers' approvals (user decision).

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

## Verification

```bash
swift test --filter CanvasCodexApprovalTests
swift test --filter CanvasBridgeLaunchTests
```

## Related

- Decision: [`0042-answer-agent-requests-from-up-next.md`](../decisions/0042-answer-agent-requests-from-up-next.md)
  (answer on the agent's own channel; the terminal stays in charge).
- [`claude-permission-request-hook.md`](claude-permission-request-hook.md): the Claude Code side of the same path.
- [`notch-companion.md`](notch-companion.md): the approval rows that show these requests.
