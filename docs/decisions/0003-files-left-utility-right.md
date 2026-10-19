# ADR 0003: Files-only left sidebar with a right utility panel

- **Status:** Accepted (supersedes the navigation-placement portion of ADR 0002)
- **Date:** 2026-07-13

## Context

ADR 0002 established one mode-switching Navigator (Files/Search/Source Control)
behind an activity strip, placeable on either window edge. The user's hands-on
acceptance pass of the pre-initial-push workbench gave explicit direction:
the left sidebar should contain only the file tree, and Git plus workspace
search belong on the right side of the window. The mode-switching strip also
hid the file tree whenever Search or Source Control was active, which made the
two-panel workflows (browse files while reviewing changes) impossible.

## Decision

- The leading `NavigationSplitView` sidebar hosts **only the Files tree**, with
  a compact header (workspace name, Search / New File / New Folder actions).
- A **right utility panel** hosts Search and Source Control, toggled from a
  slim always-visible icon rail on the window's trailing edge. Selecting the
  active mode again closes the panel.
- `WorkspaceSession.navigatorMode` is reinterpreted: `.files` now means "right
  panel closed"; `.search`/`.sourceControl` select the open pane. Persisted
  restoration state remains compatible.
- The `navigatorPlacement` preference and its menu/palette commands were
  removed; placement is no longer configurable.
- Editor-hosted diffs/details from ADR 0002 are unchanged.

## Consequences

- Files remain visible while searching or reviewing Git state.
- One fewer preference and no dual `NavigationSplitView`/`HSplitView` layout
  branches in `WorkspaceWindowView`.
- ADR 0002's remaining decisions (editor groups, authoritative selection, one
  system sidebar toggle) stay in force.

## Superseded by ADR 0030 (2026-10-19)

On the user's direction, [ADR 0030](0030-framed-workbench-left-rail-and-detached-tabs.md)
replaces the mode placement above: one always-visible **left** Activity Rail
carries all five modes (Files, Search, Source Control, Terminals, History), and
the right rail and right utility panel are removed. `navigatorMode` is
reinterpreted a second time — it now names the section the left sidebar shows and
can never mean "closed"; visibility is the separate `isSidebarCollapsed` state.
The editor-hosted diffs/details clause above still holds.
