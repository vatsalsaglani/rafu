# ADR 0046: A meeting agent with no visible terminal

- **Status:** Accepted in principle on the user's direction (2026-11-22), amended 2026-11-23. Claude Code 2.1.330 is
  held with the selected array; see the note about hidden meeting agent limits
  ([`docs/references/meeting-hidden-agent-limits.md`](../references/meeting-hidden-agent-limits.md); checked
  2026-11-22). Codex is offered in version 1 by the user's decision of 2026-11-23, with a different limit (decision
  11). The Codex 0.171.0 file-reading design was not held in the check of 2026-11-22. The new Codex design (the
  meeting text on standard input, no shell, a new empty folder for each run) was re-checked on 2026-11-23 and held
  every attempt on Codex 0.171.0; the exact array is in the limits note. Note for decision 2: Codex gets no file,
  only the text of one meeting on standard input.
  **Superseded in part on 2026-11-23** by the decision about the meeting agent probe and the automatic meeting
  summary ([`0049`](0049-meeting-agent-probe-and-automatic-summary.md)). It replaces: the "one user action for each
  run" rule of decision 3 (two exceptions), the "shows which agent gets the text before the first run" rule of
  decision 5 (for a summary run only), the manual Codex version re-check of decisions 8 and 11 (the probe replaces
  it), and the sentence "No summary is made at Stop" of decision 12. Decision 10 stays.
- **Date:** 2026-11-22
- **Related:** the decision about external agent CLIs in the Ensemble
  ([`0018-conductor-external-agent-orchestration.md`](0018-conductor-external-agent-orchestration.md)), the decision
  about Agent Terminals ([`0021-agent-terminals.md`](0021-agent-terminals.md)), the decision about voice through
  GPT-Live ([`0035-voice-through-gpt-live.md`](0035-voice-through-gpt-live.md)), the decision about Meetings scope,
  app-data storage and agent access
  ([`0047-meetings-scope-app-data-storage-and-agent-access.md`](0047-meetings-scope-app-data-storage-and-agent-access.md)),
  the Meetings phase ([`meetings.md`](../plans/phases/meetings.md)).

## Context

Today, Rafu starts a process only in a visible terminal node, and Rafu embeds no agent (`AGENTS.md`, mission
paragraph). The decision about external agent CLIs in the Ensemble (0018) says Rafu embeds no agent and holds no
inference credentials. The fourth amendment of the Workspace Canvas decision (0025) says that Rafu features may use
the user's provider key from Keychain, and that Ensemble agents never receive it.

Meetings needs two things that a person cannot get from a transcript alone: answers to questions about one meeting
("what did we decide about the release date?"), and suggestions for speaker names ("Speaker 2 is probably Anna").
Both need a language model.

A visible terminal on a hand-off folder would work under the current rule. But it ties the meeting to a workspace
window and a folder. The user rejected that: a meeting belongs to the app, not to a workspace (see the decision about
Meetings scope, 0047).

## Decision

1. **One narrow exception.** For a question about one meeting, or for speaker-name suggestions, Rafu may start the
   user's Claude Code or Codex with no visible terminal.
2. **Limit, for Claude Code.** The run is read-only and sees only the files of that one meeting. It has no write
   access, no shell command, no web tools and no MCP tools. Codex has a different limit (decision 11).
3. **Each run starts from one explicit user action.** Rafu starts no run at Stop, at launch or on a timer.
   *(Superseded in part by 0049: the probe with fixed text, and one summary run for each processing job, are
   exceptions.)*
4. **No questions during a live meeting in version 1.** A question can be asked only after the meeting has stopped
   and its transcript exists.
5. **The interface is honest about the run.** Before the first run for a meeting, it shows which agent gets the text.
   While the run works, it shows a running state and a Cancel control. The process ends when the app quits.
   *(Superseded in part by 0049: a summary run has no consent step; the summary block names the agent.)*
6. **No Rafu-held credential.** The process gets an environment from an allow list. The CLI uses its own
   authentication, as in the decision about Agent Terminals (0021).
7. **Which agents.** The ask box offers Claude Code and Codex in version 1. OpenAI with the user's API key and
   Anthropic with the user's API key come later, as a separate stage.
8. **A CLI that cannot be held to the limit is not offered in version 1.** The hidden agent limits check decides this
   for each CLI and each tested CLI version. *(Superseded in part by 0049: the probe that Rafu runs replaces the
   manual check for a Codex version.)*
9. **Name suggestions are suggestions.** The user confirms each speaker name. Rafu never applies a name by itself.
10. **This record permits this one use only.** Each other hidden process needs its own decision record.

Amendment of 2026-11-23. The user decided that Codex is offered in version 1. The design below is decided by the
advisor for the user on 2026-11-23, to be confirmed. The user can change it.

11. **A different limit for Codex.** For Codex, Rafu sends the text of one meeting on standard input. Codex runs in an
    empty private folder, with its shell tool off, a strict permission profile, no user configuration and no
    network. Codex gets no file of the user. The built-in tools that stay are listed in the limits note. The Codex
    choice is active only for a Codex version that passed the re-check. Until a version passes, the ask box shows
    Codex as "not available yet" with the reason. If the re-check fails, the ask box shows "Not available with this
    Codex version", and Claude Code works. *(The version re-check part is superseded by 0049: the probe replaces
    it.)* Rafu never puts a file named `AGENTS.md` in the Codex folder, because
    Codex applies it without being asked. Decision 2 (read-only access to the files of one meeting) applies to
    Claude Code. Decision 11 replaces it for Codex.
12. *(The sentence "No summary is made at Stop" is superseded by 0049: an automatic title and summary are on by
    default, with a Settings switch.)* **No summary is made at Stop.** The first item in the conversation column is a local overview made with no AI
    (date, length, speakers, talk time). A "Summarize" chip is a normal question: one user action, the hidden agent,
    and the answer is kept in the meeting. The line on the approved artboard becomes "Rafu writes the transcript on
    this Mac". This follows decision 3 (no run at Stop) and "keep AI explicit". (Decided by the advisor for the user
    on 2026-11-23, to be confirmed.)
13. **The question text is never a process argument.** For Claude Code, the question is in a file in a frozen copy of
    the meeting, and the prompt argument is a fixed text with no private words. For Codex, the question is on
    standard input with the meeting text. Each run has a time limit of 120 s and a limit on the size of the reply.
    "Not signed in" is read from the Claude Code `is_error` field and from the Codex 401 events.

## Alternatives considered

- **A visible terminal in a workspace window.** Rejected. It ties the meeting to a folder and a window, which the
  user does not want.
- **Provider API key only in version 1.** Rejected for version 1. The user chose the CLIs first. The API-key agents
  stay as a later stage (decision 7).
- **An embedded agent.** Rejected. It breaks the non-goal "embedded coding agent".
- **No questions.** Rejected. It removes a core use of Meetings.
- **A hidden agent with write access to a hand-off folder.** Rejected. It gives more access than the use needs.
- **Codex with a sandboxed shell in an empty folder**, if the standard-input re-check fails. Not chosen. The safe
  default is no: Codex then shows "not available". The user can decide this later.

## Consequences

- This is a new security surface. A process starts with no visible terminal, and the user cannot see its commands.
- The limit needs a test for each CLI and each CLI version. A CLI update can change a permission flag and break the
  limit, so the check must be repeatable.
- Meeting text goes to the provider of the selected CLI when the user asks a question. The interface must say this
  before the first run (decision 5).
- The Meetings code needs one place that builds the argument array, so a review can read the limit in one file.

### What stays true

- All other processes start in visible terminals.
- Rafu embeds no agent.
- Ensemble agents get no Rafu-held credential.
- AI stays explicit: no automatic send of text.
- Processes start from an executable and an argument array, never from a shell string.

## Revisit trigger

A CLI release that changes its permission flags. The start of the API-key stage. A wish for a second hidden use.

## Open

- Nothing. The Codex standard-input re-check passed on 2026-11-23 (Codex 0.171.0, 60 runs). Three flags were
  added to the candidate: `-c skills.include_instructions=false` (else the user's skills are listed to the model),
  `--disable=view_image` and `--disable=sleep_tool`. Rafu makes a new empty folder for each run, because Codex
  applies an `AGENTS.md` it finds there. A new Codex version must pass the re-check before it is offered
  *(now the probe of 0049)*.

The summary question is answered (decision 12). The Claude Code array is in the limits note. The stricter run
(the meeting text on standard input) is the Codex design; Claude Code keeps the file-reading design.

## Related paths

- [`docs/references/meeting-hidden-agent-limits.md`](../references/meeting-hidden-agent-limits.md) (checked 2026-11-22)
- `Sources/RafuCore/Meetings/` and `Sources/RafuApp/Meetings/` (planned; see the Meetings phase)
- `AGENTS.md` (mission paragraph)
