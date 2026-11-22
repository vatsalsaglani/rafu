# ADR 0047: Meetings: scope, app-data storage and agent access

- **Status:** Proposed (2026-11-22). The user decisions are recorded. Open items are listed in "Open".
- **Date:** 2026-11-22
- **Related:** the decision about a meeting agent with no visible terminal
  ([`0046-meeting-agent-without-visible-terminal.md`](0046-meeting-agent-without-visible-terminal.md)), the decision
  about meeting capture and on-device speech
  ([`0048-meeting-capture-and-on-device-speech.md`](0048-meeting-capture-and-on-device-speech.md)), the Meetings
  phase ([`meetings.md`](../plans/phases/meetings.md)).

## Context

Meetings is new. A meeting is a call that the user records and reads later. It has no relation to a folder. The user
may open a folder, or no folder, while a call is running. Rafu workspaces assume that all content is a file below a
workspace root, and Git, search and Quick Open read that root.

Agents in Ensemble terminals can already use Rafu's MCP tools. Meeting text is private. The user needs one clear
control for agent access, and the agent needs a way to know that it has no access.

## Decision

1. **A meeting belongs to the app, not to a workspace.** A folder that opens during a recording does not own the
   meeting.
2. **Storage is in the app data.** Meetings live below the `applicationSupportRoot` function of `RafuAppIdentity`
   (`Sources/RafuCore/RafuAppIdentity.swift`), which is the sole constructor for Rafu-owned state. This keeps the
   Rafu Lightning and release roots apart.
3. **Meeting data never shows as workspace content.** It is not a workspace file, a Git change, a search result, a
   Quick Open entry or restoration data.
4. **Export is Markdown only.** It runs on a user action: Copy or Export.
5. **Agent access is one Settings switch.** The switch "Allow agents to read your meetings" is off by default. The
   app checks it for each tool call.
6. **The Rafu skill checks access first.** The skill that ships with Rafu's MCP tools tells each agent to check its
   access to meetings before it works from a meeting. With no access, the agent says so plainly.
7. **The standalone Meetings window shows one meeting at a time, with no tabs.** A new recording can start while a
   meeting is processing.
8. **Command-Shift-M opens Meetings.** Record on the Welcome view opens the Meetings window.
9. **The HUD shows only during a recording.** An idle start comes from the menu bar item, the island or notch card,
   the Welcome view and Command-Shift-M.

## Alternatives considered

- **Store meetings in the workspace `.rafu/` folder.** Rejected. It shows in Git and search, and it needs a
  workspace, which a meeting does not have.
- **One grant for each agent.** Rejected. The user chose one switch.
- **More export formats.** Rejected. The user chose Markdown.
- **A database as the source of truth.** Rejected. Plain files with a rebuildable index are simpler to recover after
  a crash or a corrupt index.

## Consequences

- The meeting store is not a `WorkspaceFileSystem`. Code that reads meetings does not share the file-tree path.
- There is a second search path, for meetings only.
- Agent tools take meeting ids, never file paths. A tool never builds a path from agent input.
- The app checks the access switch on every tool call, not once at start. A change of the switch takes effect at
  the next call.

### What stays true

- Workspace identity rules.
- Secrets stay in Keychain.
- No transcript text goes into logs.

## Revisit trigger

A request for a second export format. A wish to link a meeting to a workspace. A change of the access model, for
example a grant for each meeting.

## Open

Nothing here is decided.

- A per-meeting switch "Let agents read this meeting" in Share, or the Settings switch only.
- "Open Folder..." in the Meetings window: does it open a new window, or change the same one?
- How long to keep audio and transcripts.
- Whether Command-Shift-M works only from the menu, or system-wide.
- How Meetings looks on macOS 15: a "Needs macOS 26" message, or hidden.
- Which Rafu terminals get the Rafu tools for meetings.

## Related paths

- `Sources/RafuCore/RafuAppIdentity.swift`
- `Sources/RafuCore/Meetings/`, `Sources/RafuApp/Meetings/` (planned)
- `Sources/RafuCore/CanvasBridge/CanvasAgentTools.swift` (the MCP tool list that the meeting tools join)
