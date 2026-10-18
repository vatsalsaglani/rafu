# Agent History: reading Claude Code and Codex transcripts

- Applies to: the read-only Agent History feature (round-2 workstream X12):
  `Sources/RafuCore/AgentHistory/**` (parsers, scanner, index) and
  `Sources/RafuApp/AgentHistory/**` (History navigator, Agent Session tab,
  Settings group), and the agent handoff built on it
  (`Sources/RafuCore/AgentHandoff/**`, `Sources/RafuApp/AgentHandoff/**`).
  Read it before you change a parser, a bound, the resume command, or the
  handoff file.
- Last verified: 2026-10-18. Parsers and scanner: Swift 6.2 Linux toolchain
  (swift.org `ubuntu24.04`), scratch SwiftPM package, 36 Swift Testing tests.
  Claude Code format: local transcripts written by Claude Code 2.1.x (read
  for structure only; no text copied). Codex format: the `codex-rs/protocol`
  sources (`SessionMeta`, `SessionMetaLine`, `GitInfo`, `TurnContextItem`,
  `ResponseItem`, `ContentItem`, the `*_OPEN_TAG` constants) on the
  openai/codex `main` branch on the same date, and Cider's
  `CodexSessionTitles` for `session_index.jsonl`. No Codex rollout was on the
  machine, so the Codex fixtures are synthetic. The handoff core and the
  handoff review model were run in the same scratch way (58 core tests and 9
  model tests passed on 2026-10-18). The SwiftUI layer was checked
  with `swiftc -parse` and `swift-format lint --strict` only; a Mac build is
  still required.

## Rule or observed behavior

### Where the files are

| Provider | Folder | Override |
|---|---|---|
| Claude Code | `<config>/projects/<encoded-cwd>/<session-id>.jsonl`; `<config>` is `~/.claude` | `CLAUDE_CONFIG_DIR` |
| Codex | `<home>/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`; `<home>` is `~/.codex` | `CODEX_HOME` |
| Codex thread names | `<home>/session_index.jsonl` | `CODEX_HOME` |

`AgentHistoryLocations.resolve` accepts an absolute path or `~/…` and
ignores anything else. A GUI app opened from Finder or the Dock does not get
the variables a login shell exports, so Settings > Agents > Agent History
shows the resolved folders.

Claude Code also writes subagent transcripts one folder deeper
(`projects/<folder>/<session>/subagents/…`). The scanner reads only
`projects/*/*.jsonl`, so these never appear as separate sessions.

### Claude Code lines

Each line is one JSON object with `type`. Observed types: `user`,
`assistant`, `system`, `summary`, `ai-title` (`aiTitle`), `custom-title`
(`customTitle`), `attachment`, `last-prompt`, `mode`, `queue-operation`,
`cost-state`, and more. **Ignore every unknown type.** A file can start
with `ai-title` (no `cwd`), so read `cwd` from the first entry that has it.

- Project path = the entry's `cwd`. The folder name replaces every
  non-alphanumeric character with `-`, so it is lossy; it is only a
  last-resort label (`fallbackProjectLabel`), never a path.
- Title order: last `custom-title` (a user rename), last `ai-title`, last
  `summary`, first real prompt, first slash command, "Untitled Session".
- A real prompt is a `user` entry that is not `isMeta`, not
  `isCompactSummary`, not `isSidechain`, and whose text is not wrapped in a
  CLI tag. `<command-name>/x</command-name><command-args>y</command-args>`
  becomes the command `/x y`; `<bash-input>` becomes `! …`. A `user` entry
  whose content is a block list of `tool_result` items is tool output.
- `assistant` content blocks: `text` (reply), `thinking` (hidden by default),
  `tool_use` / `server_tool_use` (one collapsed line; the `id` maps the later
  `tool_result.tool_use_id` back to the tool name).

### Codex lines

Each line is `{"timestamp", "type", "payload"}`. The first is
`session_meta` with `id`, `cwd`, `timestamp`, `originator`, `cli_version`,
`source`, and optional `git` (`branch`, `commit_hash`, `repository_url`).
Then `response_item`, `event_msg`, `turn_context` (has `cwd`), `compacted`.

- `response_item` payload types used: `message` (role `user` / `assistant`;
  content items `input_text` / `output_text`), `function_call` (`name`,
  `arguments` JSON string, `call_id`), `custom_tool_call` (`input`),
  `function_call_output` / `custom_tool_call_output` (`output`: a string, a
  JSON string `{"output", "metadata": {"exit_code"}}`, an object with
  `content`, or a list of content items), `local_shell_call`,
  `web_search_call`, `reasoning` (`summary[].text`; `encrypted_content` is
  never read). `role: developer` messages are skipped.
- Codex injects context as user messages: `<user_instructions>`,
  `<environment_context>`, `<permissions instructions>`, AGENTS.md text
  (`# AGENTS.md instructions…`), and other `*_OPEN_TAG` values. All of them
  are tag names with `_`, `-`, or a space. Rafu treats any user text that
  starts with such a tag as injected. A prompt that starts with a plain HTML
  tag (`<div>`) stays a prompt.
- Older rollouts can hold only `event_msg` `user_message` / `agent_message`;
  the parser uses them only when no `response_item` message exists, so new
  rollouts are not shown twice.
- `source: {"subagent": …}` marks a helper thread; the list hides it.
- `session_index.jsonl` is append-only `{"id", "thread_name", …}`. The last
  complete row for an id wins. Read a bounded tail (4 MiB), drop the partial
  first and last row, refuse symlinks, and flatten the name to one line.
- A resumed thread can produce a second rollout with the same `id`; the
  newest file wins.

### Bounds

| Work | Bound |
|---|---|
| Summary of one file | first 64 KiB (grows once to 1 MiB if no complete line) + last 64 KiB |
| Message count | exact when head + tail cover the file; otherwise extrapolated by size and shown as `~N` |
| Opening a transcript | first 20 MiB or 5,000 entries, then a visible "shows its first …" notice |
| One message / tool detail | 100,000 characters / 16,384 characters, marked when cut |
| Markdown rendering | messages over 24,000 UTF-8 bytes render as plain monospaced text |
| Message-text search | 8 MiB per file, prompts and replies only |
| Files per provider | newest 5,000 |
| Title | 120 characters, one line |

Measured on Linux (release build), one real 21 MB Claude Code transcript:
summary 14 ms, rescan reuse 0 parses, full open 752 ms to the 20 MiB bound
(593 entries).

### Caching and threads

`AgentHistoryScanner` is an actor. It caches summaries by path and checks
(modification date, size); a rescan parses only new or changed files and
drops removed ones. Transcript loading and message search are `@concurrent`.
`AgentHistoryStore.shared` does nothing until a History navigator appears
(`loadIfNeeded`), and skips a rescan within 30 s of the last one; Refresh and
the Settings toggles rescan explicitly. There is no file watching.

### Resume

`AgentHistoryResumeCommand.arguments` builds `["claude", "--resume", id]` or
`["codex", "resume", id]`, and refuses an id with characters other than
letters, digits, `-`, `_`, `.` (or a leading `-`). `shellLine` joins them with
POSIX single quoting (`'` becomes `'\''`). Rafu opens an ordinary shell
Terminal Group in the session's folder and types that one line only after
the user clicks Resume in Terminal. The folder must be inside a Rafu window's
workspace (Terminal Groups are bounded to the workspace root): this window,
or another open window that then comes to the front. Otherwise Rafu says so
and offers Open Project Folder. A missing folder is reported, not created.

### Open Project Folder

The key window consumes `ExternalOpenRequests.pending` itself, so a plain
`enqueue` from a focused window replaces that window's workspace. Agent
History uses `enqueueForNewWindow`, which only a new scene's startup takes
(`takeForNewWindow` in `WorkspaceSceneRoot`). A window that already shows
the folder is focused instead.

### Agent handoff ("Continue in Codex…" / "Continue in Claude Code…")

Code: `Sources/RafuCore/AgentHandoff/*` (nonisolated, Linux-testable) and
`Sources/RafuApp/AgentHandoff/*` (review sheet, menus, launch). Tests:
`Tests/RafuCoreTests/AgentHandoff/*`, `Tests/RafuAppTests/AgentHandoff/*`.

**Entry points.** History row menu and the Agent Session tab's More menu
(`AgentHandoffMenuItems`), the palette ("Continue Session in …", only while an
Agent Session tab is on screen), and the Ensemble terminal card menu ("Hand off
to Codex…" on a Claude Code card and the other way round;
`AgentHandoffCardMenuItems`). The card uses
`AgentHistoryIndex.newestSession(provider:inFolders:)`: the newest History
session whose `cwd` equals the card's folder and whose provider equals the
card's agent. With no match the item is disabled (History loaded) or loads
History first (History never loaded; `AgentHistoryStore.ensureIndexLoaded`
waits on the store's observation, not on a timer).

**Review sheet.** Target agent; range (All turns or Last N turns, default 30,
1 to 500); tool calls (default on, one line each); tool outputs (default off);
thinking is never an option; one checkbox per image (default on); a size
estimate; "Where" is `.rafu/handoffs/` in this window's project; a
`.gitignore` checkbox (default on only when the folder has `.git` and no line
already covers it). Buttons: Cancel, Write Handoff, Write & Start. Nothing is
written or started before a click.

**Files.** `.rafu/handoffs/<yyyy-MM-dd-HHmm>-<slug>/HANDOFF.md` plus
`image-NN.<png|jpg|gif|webp>` in the same folder. The slug is lowercase ASCII
words joined by `-`, at most 40 characters (`session` when empty). The folder
is created with `createDirectory(withIntermediateDirectories: false)`; a name
that exists gets `-2`, `-3`, … (never reused). Every directory is resolved
through symbolic links and must stay inside the resolved project root, else
`outsideProject` and nothing is written. Files are written atomically; a
failure removes the new folder. File names must match `image-<digits>.<ext>`.

**`HANDOFF.md`.** Header (source agent, title, original folder, branch, start
and end time as ISO 8601, target agent, turn count, image counts), a
"Continue from here" note, notes for turns left out (range, size, unread
start of a huge session), then `## Conversation`:
`### User` and `### Claude Code` / `### Codex` per run of one role; assistant
text; tool calls as `> tool: Name — short args` (one line each); tool outputs
only on request, as `> tool output: Name` plus a fenced block longer than any
backtick run inside it, cut at 2,000 characters; images inline as
`![image-01](image-01.png)` (a prompt shows its images before its text, a
reply after it); `> image left out: <reason>` for an image that is not
included. Then `## Attachments` (see below). Limits: 200 KB of Markdown (older
turns are dropped first and the header says so; one turn that is still too big
has its message text cut to 8,000, 2,000, then 500 characters, then the file
is cut at a UTF-8 boundary), 30,000 characters per message, 3,000 entries
kept, 256 MiB read (a larger file is read from its end). Thinking and Codex
`reasoning` items never leave the loader.

**Images.** Found while reading the session, but only *pointers* are kept
(file offset, line length, ordinal in the line). Bytes are decoded when the
review sheet needs them, by re-reading that one line. Bounds: at most 20
images (the newest in the chosen range), 5 MB after decoding (checked on the
base64 length before decoding), PNG/JPEG/GIF/WebP by magic bytes only (the
claimed media type is ignored),
de-duplicated by SHA-256 (equal bytes share one file), skipped ones are shown
in the sheet and as `> image left out:` lines. Web addresses are never
fetched. Tool-result images are included only together with tool outputs.

**Attachments.** Paths from Claude `attachment` entries of type `file`
(`filename`), `@path` mentions in user prompts (a token that starts with `@`
and holds a `/` or a file extension), and the `file_path` argument of tool
calls. Each is listed as "available in the project" (inside the resolved
project root), "outside the project — not copied", or "missing", at most 100.
Non-image files are never copied.

**Starting the agent.** "Write & Start" builds an argument array (no shell
string) with `AgentHandoffLaunch`:
`["claude", "<prompt>"]` or `["codex", "<prompt>", "--image", "<abs>", …]`.
The prompt is one line, at most 4 KB: `Read <path to HANDOFF.md>. It is a
<Source> session about "<title>". Continue the task from where it stopped.
Images referenced there are in the same folder.` The path is
`.rafu/handoffs/<name>/HANDOFF.md` when the terminal starts in the project
root, else absolute. Claude Code gets the image paths in the prompt (it reads
image files from paths); Codex gets one `--image` per file. The Codex flag is
`-i, --image <FILE>…` and takes one or more values, so the prompt comes first
and each file has its own flag; a path with a comma (the flag splits at
commas) or a leading `-` is listed in the prompt instead. The flag name comes
from the Codex CLI documentation and was not run on this machine. From
History: a new Agent Terminal process in the session's folder (the project
root if the folder is gone or outside this window's project), same
executable, environment, and folder rules as an Agent Terminal. From an
Ensemble card: a new stopped terminal card to the right of the source card,
joined by a "handoff" relationship link (one undo step), started through the
card's own Start path, then the shell line is typed (single-quoted).

**Verified field names** (this machine, Claude Code 2.1.302, keys only,
2026-10-18):

- User message image: `message.content[]` block `{type: "image", source:
  {type: "base64", media_type: "image/png" | "image/jpeg", data}}`; the text
  of the prompt is a later `{type: "text"}` block in the same entry.
- Tool-result image: `message.content[]` block `{type: "tool_result",
  tool_use_id, content: [{type: "image", source: {type: "base64",
  media_type, data}}, …]}`.
- `attachment` entries (`type: "attachment"`) with `attachment.type` of `file`
  hold `filename`, `displayPath`, and `content`; Rafu reads the two path keys
  only. `attachment.type` of `queued_command` holds `prompt[]` with image
  blocks; Rafu ignores it (the prompt reaches the transcript as a `user`
  entry when it runs).
- Not used: `toolUseResult.file` (a Read result that repeats a tool-result
  image).
- Codex (`codex-rs/protocol`, read earlier on 2026-10-18; no rollout with an
  image exists on this machine): `response_item` payload `message` with
  `content[]` items `{type: "input_image", image_url}`; `image_url` is a
  `data:<media>;base64,…` URL. The parser is tolerant: `output_image` and
  `image` item types, `image_url` as `{url}`, `url`, `path`, `file://` URLs,
  absolute paths, and `function_call_output` outputs that are content-item
  lists. Codex may wrap images in `<image>` / `</image>` text items (not
  confirmed on this machine); the renderer removes such lines and the
  `[Image]` placeholder.

**Not supported.** Fetching web images; non-image attachments (listed, not
copied); thinking; subagent threads; SVG, HEIC, PDF; writing outside the
project root; Windows paths; a project other than the one this window has
open (the files always go to this window's project, and the sheet says so when
the session ran elsewhere); pasting the handoff into an agent that already
runs.

## Why it matters

- Transcripts hold private prompts, code, and tool output. Rafu reads them
  only: no writes, no upload, no logging of titles, paths, or text. Error
  messages never include file content or full paths.
- The formats are undocumented and change between CLI versions. Tolerant
  parsing (skip malformed lines, ignore unknown types) keeps History working
  when a CLI adds an entry type.
- Bounded reads keep a 100 MB session from stalling the app or holding
  memory; only an open tab holds parsed text, and it is released on close.

## Reproduction or evidence

- `Tests/RafuCoreTests/AgentHistory/*` (synthetic fixtures in
  `AgentHistoryFixtures.swift`): titles, cwd, branch, times, injected-context
  skipping, subagent hiding, tool mapping, both limits, rescan reuse,
  cancellation, message search, partition, path rules, quoting.
- `Tests/RafuAppTests/AgentHistory/AgentHistoryTabTests.swift`: navigator
  mode encoding, tab identity, open/select/close releasing the transcript,
  Settings exclusivity, failure text without a path.
- Structure of local Claude Code 2.1.x transcripts was confirmed by counting
  entry types and keys only (no text printed).

## Verification

```bash
./script/test.sh --filter AgentHistory     # on a Mac
./script/test.sh --filter AgentHandoff     # on a Mac: handoff images, Markdown, writer, argv
./script/build_and_run.sh --verify          # History rail, tab, Resume, Settings
```

On Linux, copy `Sources/RafuCore/AgentHistory/*.swift`,
`Sources/RafuCore/AgentHandoff/*.swift`, and the core tests
into a scratch package named `RafuCore` (see
[`linux-swift-verification.md`](linux-swift-verification.md)) and run
`swift test`.

## Related code, ADRs, and phases

- Phase: [`../plans/phases/ensemble-canvas.md`](../plans/phases/ensemble-canvas.md),
  Addendum 2, X12 and the "Agent history (X12)" contract.
- Code: `AgentHistoryScanner`, `ClaudeCodeHistoryParser`,
  `CodexHistoryParser`, `CodexSessionIndex`, `AgentTranscriptLoader`,
  `AgentHistoryResumeCommand`, `AgentHistoryStore`,
  `AgentHistoryWindowState`, `AgentTranscriptModel`,
  `WorkspaceSession+AgentHistory.swift`, `WorkspaceAuxiliaryTab.agentSession`.
- Related notes: [`concurrency.md`](concurrency.md),
  [`editor-dependencies.md`](editor-dependencies.md) (MarkdownUI boundary).
