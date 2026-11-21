# ADR 0043: Navigator number keys, the sidebar on either edge, and Zen mode

- **Status:** Accepted (2026-11-21) on the user's direction (switch the navigator sections with a key and show which
  key on screen, move the sidebar to the right edge with one command, and add a Zen mode that hides the sidebar).
  GUI checks pending (listed below).
- **Date:** 2026-11-21
- **Amends:** the framed workbench decision with one left Activity Rail, a raised deck and detached tabs
  ([`0030-framed-workbench-left-rail-and-detached-tabs.md`](0030-framed-workbench-left-rail-and-detached-tabs.md)):
  the rail and sidebar may now sit on the trailing edge by user preference. The left edge stays the default.
- **Retains:** the native workbench navigation decision
  ([`0002-native-workbench-navigation.md`](0002-native-workbench-navigation.md)): one navigator, one sidebar toggle
  (in the title bar, beside the traffic lights, on both edges) and no second toggle in a panel header.
- **Related:** [`navigator-shortcut-hint-monitor.md`](../references/navigator-shortcut-hint-monitor.md), the active
  phase ([`pre-initial-push-workbench.md`](../plans/phases/pre-initial-push-workbench.md)).

## Context

The rail switches between six navigator sections (Files, Search, Source Control, Terminals, Ensembles, History).
Only some had a menu shortcut, none had a number key, and nothing on screen said which key did what. Some users also
want the sidebar on the right, and a way to hide the whole navigator for focus.

## Decision

1. **Number keys.** Command 1 to Command 6 switch to Files, Search, Source Control, Terminals, Ensembles and History,
   in rail order. Each also has a View menu item. A key always shows the section and never hides the sidebar when
   that section is already shown (the rail icon toggles; the key does not). A section that needs a folder (every one
   but Files) is disabled without one, by the same rule as its rail icon (`isNavigatorModeAvailable`).
2. **Badges on hold.** Holding Command alone for 0.5 s shows a small "⌘1" to "⌘6" label at the bottom right of each
   rail icon. A key press, another modifier, or a change of key window hides them until Command is pressed again, so
   a quick Command S or Command B never flashes them. The badges are hidden from VoiceOver: each button has the hint
   "Command 1" and a tooltip with the shortcut in brackets.
3. **Sidebar edge.** The View menu, the command palette and Option Command B move the rail and sidebar to the other
   window edge. On the trailing edge the order is deck, sidebar, rail, so the sidebar opens toward the leading side.
   The choice is one per-user setting (`workbench.sidebarEdge` in `UserDefaults`, values `leading` and `trailing`).
   Every open window follows it at once. It is not part of workspace restoration. An unknown stored value reads as
   leading. The sidebar toggle stays in the title bar on the leading side on both edges, so the window still has one
   toggle. The seam handle mirrors: on the trailing edge a drag toward the leading side widens the sidebar
   (`WorkbenchSidebarResize.outwardTranslation`), and collapse and reopen follow the same sign.
4. **Zen mode.** Control Command Z, the View menu and the command palette hide the rail and the sidebar in the
   current window only. The title bar and the status bar stay. Zen mode is not saved: a relaunch starts with the rail
   and sidebar shown. Zen mode ends with the same command, Command B, the title bar toggle, a rail click, Command 1
   to Command 6, any "Show …" command (`showNavigator`), or Escape.
5. **Escape leaves Zen mode only when nothing else could want the key.** It does not leave Zen mode when the first
   responder is a text field or text view (the editor, a search field, the command palette), a terminal, when a sheet
   is attached, when the editor tab switcher is open, or when an Ensemble board is the selected tab (the board uses
   Escape). In all those cases Escape goes to its owner unchanged. Escape is taken only for a plain key press in the
   window's own key state.
6. **Shortcuts, chosen after a search of the code.** Command 1 to Command 6 were free (the only digit shortcuts are
   Shift Command 1 for Show All Workspaces, and Command 9, Option Command 9 and Command 0 for the Ensemble view, none
   in conflict). Option Command B (move the sidebar) and Control Command Z (Zen mode) were free; neither collides with
   an editor key binding (the editor uses Command and Control with letters only for symbol navigation: Control Command
   J and R). Command Shift Z (redo) and Control Command F (full screen) are deliberately not used.
7. **VoiceOver.** Entering Zen mode posts "Zen mode on. Press ⌃⌘Z to leave." Leaving posts "Zen mode off."

## Alternatives considered

- **Control Command 1 to 6 instead of Command 1 to 6.** Not needed: no digit conflict exists, and plain Command digits
  are what users expect. The plan kept this as the fallback.
- **A key press hides the badges only for a moment.** Rejected: a held-Command shortcut would flash them on every
  Command S.
- **Hiding the sidebar by collapsing it (no Zen mode).** Rejected: collapse keeps the rail, and the collapse bit is
  saved. Zen mode is a separate, unsaved window state, so a quit in Zen mode never reopens a window with no navigator.
- **A second sidebar toggle on the trailing edge.** Rejected: the one-toggle rule stays.
- **Mirroring the whole window layout with the layout direction.** Rejected: it would also flip text and the editor.

## Consequences

- The rail and sidebar are one view (`WorkbenchNavigatorColumn`) placed before or after the deck. Moving the edge
  recreates the column, so the sidebar scroll position resets once (the section, selection and width are session
  state and survive).
- One local event monitor per window reads modifier and key events. It returns every event unchanged, except an
  Escape that leaves Zen mode.
- Escape does nothing in Zen mode on an Ensemble board. Command B, the title bar toggle, a number key and the menu
  still leave Zen mode there.
- Focus is not moved when Zen mode hides a focused sidebar: AppKit drops the first responder and the user clicks or
  tabs to the editor. There is no shared "focus the editor" action to call (gap noted).

## Revisit trigger

- A user asks for Zen mode to persist, or for the title bar toggle to follow the sidebar edge.
- A shared "focus the deck" action appears; Zen mode should then use it.

## GUI checks pending

Two windows: badges appear only in the key window after about 0.5 s of Command alone; a quick Command S or Command B
does not flash them; Command 1 to Command 6 switch; History is disabled with no folder. Move Sidebar to Right: both
windows move at once, the seam drag resizes the right way, a drag to the edge collapses and a drag outward reopens,
Command B and the title bar toggle work, the setting survives a relaunch. Zen: hides the rail and sidebar in this
window only, the status bar stays, every exit above works, Escape in the editor, a terminal and a text field goes to
them, off after a relaunch. An Ensemble card at the seam takes no clicks from the sidebar on either edge. VoiceOver
reads the rail titles and hints and not the badges, and the Zen announcement is heard.

## Related paths

`Sources/RafuApp/Views/WorkbenchLayoutPreferences.swift`, `NavigatorShortcutHints.swift`, `WorkbenchSplitHandle.swift`,
`WorkspaceNavigatorView.swift` (`WorkbenchNavigatorColumn`), `WorkspaceWindowView.swift`;
`Sources/RafuApp/App/WorkbenchLayoutCommands.swift`; `Sources/RafuApp/Models/WorkspaceSession.swift`
(`switchNavigator`, `isZenMode`).
