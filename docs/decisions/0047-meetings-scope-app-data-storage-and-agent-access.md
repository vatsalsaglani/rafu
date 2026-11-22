# ADR 0047: Meetings: scope, app-data storage and agent access

- **Status:** Accepted (2026-11-23). The user said on 2026-11-23: build the rest of the meeting note-taker. The six
  items that were open on 2026-11-22 are now answered. The advisor answered all six for the user (decisions 10 to
  15). The user decided the diagnostics log (decision 16). Each advisor answer says "decided by the advisor for the
  user on 2026-11-23, to be confirmed". The user can change it.
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

Answers of 2026-11-23 to the six items that were open. Each answer was decided by the advisor for the user on
2026-11-23, to be confirmed.

10. **Which terminals get the Rafu tools for meetings.** Ensemble terminals only, as today. "Any agent" means each
    agent that has the Rafu tools. The bridge does not change. Only the Ensemble terminal bootstrap sets the
    `RAFU_CANVAS_*` variables, and the terminal child environment removes inherited ones. A wider bridge is a
    separate security change.
11. **No switch for each meeting in Share.** The Settings switch only. The Share sidebar shows one status line
    ("Agents can read your meetings" or "Agents cannot read your meetings") with a button that opens Settings ▸
    Meetings. A grant for each agent was already rejected.
12. **"Open Folder..." in the Meetings window opens a workspace window** beside the Meetings window. The Meetings
    window does not change. A meeting belongs to the app, each workspace window owns one `WorkspaceSession`, and
    Meetings is a scene of its own.
13. **Retention.** Transcripts stay until the user deletes the meeting. Audio: Settings ▸ Meetings ▸ "Keep audio" has
    three values: "Until I delete" (the default), 30 days and 7 days. The meeting list shows the size of each
    meeting. Rafu never deletes audio that the user did not ask it to delete, because a deletion cannot be undone and
    the audio is needed to make the text again with the second engine.
14. **Command-Shift-M is a menu command.** It is active only when Rafu is in front. It is not system-wide. A start
    from another app comes from the menu bar item and the island or notch card. Reason: Microsoft Teams uses
    Command-Shift-M for mute, and a system-wide key would take it during a call. No other Rafu command uses
    Command-Shift-M.
15. **Meetings on macOS 15.** The entry points show. They are not active and say "Meetings needs macOS 26". There is
    no capture, no helper and no permission prompt.

Decided by the user on 2026-11-23:

16. **Meeting diagnostics, built in from the start.** The user tests on another Mac and sends the logs back. Each
    meeting has one diagnostics file in the app data (JSON lines, bounded in size, rotated, and kept for the newest 20
    meetings), and `Logger` with the subsystem `dev.vatsalsaglani.rafu` and the category `meetings`. A user action,
    "Export Meeting Diagnostics...", writes one bundle through a save panel. Nothing is written or sent without the
    save panel. The log has no transcript text, title, speaker name, question, answer or audio path. Its events are
    typed: numbers, enums, ids, error codes, device facts and model ids. A device name can hold a person's name, so
    the export sheet says what the bundle holds: "Device names, app identifiers, error codes and timings. No
    transcript, no audio." Deleting a meeting deletes its diagnostics file.

## Alternatives considered

- **Store meetings in the workspace `.rafu/` folder.** Rejected. It shows in Git and search, and it needs a
  workspace, which a meeting does not have.
- **One grant for each agent.** Rejected. The user chose one switch.
- **A switch for each meeting in Share.** Rejected on 2026-11-23 (decision 11).
- **A system-wide Command-Shift-M.** Rejected on 2026-11-23 (decision 14).
- **A bridge that gives the Rafu tools to every terminal.** Rejected on 2026-11-23 (decision 10).
- **Hide Meetings on macOS 15.** Rejected on 2026-11-23 (decision 15).
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
- No transcript text goes into logs or into the diagnostics export.

## Revisit trigger

A request for a second export format. A wish to link a meeting to a workspace. A change of the access model, for
example a grant for each meeting. A wish to give the Rafu tools to terminals outside the Ensemble. A wish for a
shorter default audio retention.

## Open

Nothing is open. The six items of 2026-11-22 are answered in the Decision list (decisions 10 to 15).

## Related paths

- `Sources/RafuCore/RafuAppIdentity.swift`
- `Sources/RafuCore/Meetings/`, `Sources/RafuApp/Meetings/` (planned)
- `Sources/RafuCore/CanvasBridge/CanvasAgentTools.swift` (the MCP tool list that the meeting tools join)
