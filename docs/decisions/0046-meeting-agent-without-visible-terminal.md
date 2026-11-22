# ADR 0046: A meeting agent with no visible terminal

- **Status:** Accepted in principle on the user's direction (2026-11-22). The argument arrays are not verified; see
  the note about hidden meeting agent limits (`docs/references/meeting-hidden-agent-limits.md`, to come).
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
2. **Limit.** The run is read-only and sees only the files of that one meeting. It has no write access, no shell
   command, no web tools and no MCP tools.
3. **Each run starts from one explicit user action.** Rafu starts no run at Stop, at launch or on a timer.
4. **No questions during a live meeting in version 1.** A question can be asked only after the meeting has stopped
   and its transcript exists.
5. **The interface is honest about the run.** Before the first run for a meeting, it shows which agent gets the text.
   While the run works, it shows a running state and a Cancel control. The process ends when the app quits.
6. **No Rafu-held credential.** The process gets an environment from an allow list. The CLI uses its own
   authentication, as in the decision about Agent Terminals (0021).
7. **Which agents.** The ask box offers Claude Code and Codex in version 1. OpenAI with the user's API key and
   Anthropic with the user's API key come later, as a separate stage.
8. **A CLI that cannot be held to the limit is not offered in version 1.** The hidden agent limits check decides this
   for each CLI and each tested CLI version.
9. **Name suggestions are suggestions.** The user confirms each speaker name. Rafu never applies a name by itself.
10. **This record permits this one use only.** Each other hidden process needs its own decision record.

## Alternatives considered

- **A visible terminal in a workspace window.** Rejected. It ties the meeting to a folder and a window, which the
  user does not want.
- **Provider API key only in version 1.** Rejected for version 1. The user chose the CLIs first. The API-key agents
  stay as a later stage (decision 7).
- **An embedded agent.** Rejected. It breaks the non-goal "embedded coding agent".
- **No questions.** Rejected. It removes a core use of Meetings.
- **A hidden agent with write access to a hand-off folder.** Rejected. It gives more access than the use needs.

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

Nothing here is decided.

- Who writes the summary, and when. An automatic send at Stop is against "keep AI explicit". The approved artboard
  says "Rafu writes the transcript and the summary on this Mac". These two do not agree yet.
- The exact argument arrays for each CLI. They come from the hidden agent limits check.
- Whether a stricter run is the default: no tools at all, with the meeting text on standard input.

## Related paths

- `docs/references/meeting-hidden-agent-limits.md` (to come, from the check)
- `Sources/RafuCore/Meetings/` and `Sources/RafuApp/Meetings/` (planned; see the Meetings phase)
- `AGENTS.md` (mission paragraph)
