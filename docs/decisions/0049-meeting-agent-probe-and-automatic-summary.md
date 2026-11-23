# ADR 0049: The meeting agent probe and the automatic meeting summary

- **Status:** Accepted (2026-11-23) on the user's direction. Merged and verified on `main` (agent commits
  `4e50489a` to `a72d3175`; the exact tool-list check, the probe and one summary run per processing job all ran
  live on this Mac; see "Evidence").
- **Date:** 2026-11-23
- **Supersedes in part:** the decision about a meeting agent with no visible terminal
  ([`0046-meeting-agent-without-visible-terminal.md`](0046-meeting-agent-without-visible-terminal.md)). The affected
  parts are listed in "What this record replaces". Everything else in that record stays.
- **Related:** the decision about Meetings scope, app-data storage and agent access
  ([`0047-meetings-scope-app-data-storage-and-agent-access.md`](0047-meetings-scope-app-data-storage-and-agent-access.md)),
  the decision about Agent Terminals ([`0021-agent-terminals.md`](0021-agent-terminals.md)), the note about hidden
  meeting agent limits ([`meeting-hidden-agent-limits.md`](../references/meeting-hidden-agent-limits.md)), the
  Meetings phase ([`meetings.md`](../plans/phases/meetings.md)).

## Context

The decision about a meeting agent with no visible terminal (0046) allows one hidden use: a run that the user starts
by one explicit action, for one question or for speaker-name suggestions. Three of its rules now block work that the
user asked for:

- **"Each run starts from one explicit user action"** (its decision 3), and **"No summary is made at Stop"** (its
  decision 12). The user wants a title and a summary for each meeting with no extra step. The user decided on
  2026-11-23: the automatic title and summary are on by default, with no consent step, and a Settings switch turns
  them off.
- **The manual Codex version re-check** (its decisions 8 and 11). Codex was offered only for a version that a person
  had re-checked. Each new Codex version then showed "not available" until a person ran a long check by hand. The
  user decided on 2026-11-23: Codex must be selectable, and a check that Rafu runs itself replaces the exact-version
  lock.

The version lock protected one property. The Codex `--json` stream shows no tool list, and it is not a complete audit
log (a forced `exec` call and a forced `apply_patch` call left no item in the stream). So the stream cannot show
which tools the model had. The lock made sure that only the one binary whose tool list a person had captured could
run. Any replacement must protect the same property.

## Decision

### 1. The probe replaces the exact Codex version lock

Rafu runs a **probe** for each CLI before it first trusts that CLI, and again when the resolved path, the version,
the file modification time or the argument-array revision changes. The probe uses fixed text only. It sends no
user text.

For Codex, the probe has three steps. Each step must pass; a step that cannot be read counts as failed (fail closed).

1. **Version.** Run `--version` by the resolved path (5 s, 4 KB limit). A version that cannot be read gives
   "failed".
2. **Tool-list capture.** The protected property: Codex shows no tool list, so Rafu captures the request that Codex
   would send to the model, and checks the exact tool list. Rafu opens a listener on `127.0.0.1` (a free port, no
   other interface), runs the final Codex array with a provider setting that points to that listener, and reads
   the one request body. The tool names must be exactly the four top-level tools (`exec`, `wait`,
   `request_user_input`, `request_user_input_async`) and exactly the five nested tools in the `exec` description
   (`apply_patch`, `list_mcp_resources`, `list_mcp_resource_templates`, `read_mcp_resource`, `clock__curr_time`),
   and no message may hold a skills block. A different list gives "this version is not supported". No model and no
   account is used in this step.
3. **A small real run.** The same array, the same four-key environment, a new empty private folder and a fixed
   text. The run must finish with a non-empty answer and exit 0. It must show no "unrecognized configuration
   setting" item and no 401. Every item type must be one of `agent_message`, `reasoning` or `error`. Afterwards the
   run folder must be empty. A 401 gives "not signed in".

Every real Codex run also applies the item-type rule and the empty-folder check after it ends. A failure drops the
answer and clears the cached probe.

For Claude Code, the probe is: the version, then a small run on a synthetic meeting folder that Rafu writes. The
`init` check must pass, the reported version must equal `--version`, and the files in the folder must be unchanged.
Every Claude Code run stops when the model calls a tool other than `Glob`, `Grep` or `Read`.

The probe is a hidden process that starts with no user action for that run. It is therefore an exception to the rule
"one explicit user action for each run". The exception is narrow: fixed text, no private text, no meeting.

Only a "ready" result is kept between launches (in `UserDefaults`, key `meetings.agentProbeCache`, with path, version,
file time, argument revision and date). Any other result stays in memory. A real run that finds "not signed in", a
refused `init` or a changed setting clears the entry. One probe for one CLI runs at a time; a second caller waits
for the same probe.

If no probe result is cached yet, the availability check reports "ready", and the first real run does the probe.
The availability check starts no process.

### 2. The summary block: one summary run for each processing job

When a processing job ends (the transcript is written and the meeting is "ready"), Rafu starts **one** hidden agent
run that writes a title and a summary (a summary text, decisions and action items with citations to turns). It is a
second exception to "one explicit user action for each run": one run for each processing job, with no click.

- **On by default, no consent step.** The Settings switch `meetings.autoSummary` (default on; a missing value
  counts as on) turns it off. When it is off, Rafu starts no process after Stop. This replaces the rule "No summary
  is made at Stop".
- **Which agent.** The agent last used in the meeting detail (`meetings.detail.lastAgent`), then Claude Code, then
  Codex: the first that is ready. If none is ready, the summary shows "unavailable".
- **The interface says it.** The summary block names the agent that wrote it. The processing steps show "Writing the
  summary" while the run works, and a Cancel control stops it. Settings has the switch.
- **What leaves the Mac.** The transcript text and the speaker names go to the provider of the selected CLI. Audio
  is never sent.
- **Limits.** The answer is one JSON object. Rafu bounds it (title 80 characters, summary 8 KB, 20 decisions and 20
  action items, 400 characters for each item), cleans control characters, drops a citation to an unknown turn, and
  gives the title through the same cleaning rule as a user rename. A model reply is never a path.
- **Names.** A generated title replaces only a default title or a title that an earlier summary wrote. A name
  that the user typed is never replaced.
- **Stale text.** The summary file records the text revision it was written for. When the text is made again while
  the run works, Rafu saves nothing, and the next processing job runs again. A summary for an older revision shows
  as stale.

### 3. Other decisions of this record

- **Streaming.** An answer to a question streams (Claude Code shows several pieces; Codex shows one piece at the end,
  because its stream has no text pieces). The final text is always the `result` or the last completed message.
- **One run for each meeting and kind.** A question, a name suggestion and a summary can run together for one
  meeting. A second run of the same kind is "busy".
- **Stop ends the process group.** When Rafu owns the child's process group, Stop signals the whole group. Rafu
  never signals its own group.
- **Names found.** A name suggestion that finds nothing reports "no names found". It is not the same as "nothing to
  name".
- **Each stored answer records the text revision**, so an old answer can show as stale.

### What stays true

- The decisions of 0046 that are not listed below stay: limits for Claude Code (2) and Codex (11, apart from the
  version re-check), no question during a live meeting (4), no Rafu-held credential (6), the agents offered (7),
  name suggestions are suggestions (9), the question text is never a process argument (13).
- **No other hidden use.** Decision 10 of 0046 stays: this record permits the probe and the summary run, and nothing
  else. Each other hidden process needs its own decision record.
- All other processes start in visible terminals. Rafu embeds no agent. Ensemble agents get no Rafu-held credential.
  Processes start from an executable and an argument array. The environment has exactly four keys (`PATH`, `HOME`,
  `USER`, `LOGNAME`).

## What this record replaces

Each item names the part of 0046 that is superseded.

| Part of 0046 | Now |
|---|---|
| Decision 3, "each run starts from one explicit user action" | Two exceptions: the probe (fixed text) and one summary run for each processing job. A question and a name suggestion still need one user action. "Rafu starts no run at Stop" no longer holds for the summary. |
| Decision 5, "before the first run for a meeting, it shows which agent gets the text" | For a summary run there is no consent step. The summary block names the agent, a processing step shows the run, and the Settings switch turns it off. For a question the rule stays. |
| Decision 8 and decision 11, the version re-check by a person ("the Codex choice is active only for a version that passed the re-check"; "not available yet") | The probe replaces it. A Codex version that passes the probe is offered. A different tool list gives "this version is not supported". |
| Decision 12, "no summary is made at Stop" | Replaced by section 2 above. This record does not state a change to the local overview or to the "Summarize" chip. |
| The "Open" text, "a new Codex version must pass the re-check before it is offered" | The probe is that check. |

## Alternatives considered

- **Keep the exact-version lock.** Rejected by the user. Each Codex release would turn Codex off until a person
  re-ran a long check.
- **No check at all for a new Codex version.** Rejected. The stream shows no tool list, so a new version could add a
  tool that no one sees. The probe makes the tool list visible without a model.
- **Capture only the version and trust it.** Rejected. The same version string does not prove the same tool list for
  a changed configuration.
- **A consent step before the first automatic summary.** Not chosen. The user decided on no consent step. The
  protection is the visible agent name, the visible step, the Settings switch and the rule that audio is never sent.
- **Off by default.** Not chosen. The user wants a title and a summary with no extra step.
- **One summary run in the processing queue.** Not chosen. The run starts after the meeting is "ready", outside the
  queue, so a slow agent does not block the next processing job.

## Consequences

- The probe costs one small model call for each CLI each time its binary changes. The tool-list capture step uses no
  model and no account.
- A new Codex version that changes the request shape shows "this version is not supported". That is intended.
- A user who leaves the Settings switch on sends each meeting's text to the selected CLI's provider after each
  processing job. The Settings switch, the agent name on the summary block and the "Writing the summary" step are
  the disclosure.
- The capture listener is a local network listener, open only during the probe step. It listens on loopback only,
  on a free port, for at most 10 s. It keeps no header, and it is never open during a real run.
- The reading of the Codex stream is still not an audit log. The protection is the exact tool list, the item-type
  rule and the empty-folder check, not the stream.

### Implementation facts that differ from the plan

- The listener uses plain sockets, not `NWListener`.
- The listener accepts up to 8 connections. The plan said one. Codex opens three: two GET requests for the model list,
  then one POST of about 34.7 KB.
- The Codex stream parser emits no text. The runner sends the one text piece after the checks pass, so a text that
  fails a check is never shown.
- Whether Rafu owns the child's process group is checked at each start. Foundation `Process` gave the child its own
  group (verified live), but that is not documented behaviour.
- A full new transcript raises the text revision. Editing one turn does not.

## Evidence

- Live on this Mac (Claude Code 2.1.330, codex-cli 0.171.0, macOS 27.2): both probes returned "ready". Claude Code
  streamed several pieces; Codex streamed one. Both summaries were valid.
- A live probe test exists. It runs only with `RAFU_LIVE_AGENT_PROBE=1`.
- Both test modes (parallel and `--no-parallel`) passed on `main`. The handoff gave 4,495 app tests and 1,117 core
  tests; it did not say whether each mode ran the same count.
- Details, the capture request shape and the repeat check: the note about hidden meeting agent limits.

## Revisit trigger

A CLI release that changes the tool list, the stream shape or the permission flags. A wish for a third hidden use. The
start of the API-key stage. A user report that the default-on summary is a surprise.

## Related paths

- [`docs/references/meeting-hidden-agent-limits.md`](../references/meeting-hidden-agent-limits.md)
- `Sources/RafuApp/Meetings/Agent/` and `Sources/RafuCore/Meetings/Agent/`
- `AGENTS.md` (Meetings paragraph, and the rule "Keep Git and AI explicit")
