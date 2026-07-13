# ADR 0002: Use one native workbench navigator and editor-hosted details

- **Status:** Accepted
- **Date:** 2026-07-13

## Context

The pre-first-commit shell placed Files permanently on the left and Git in a
permanent right inspector. Hands-on review showed duplicated sidebar controls, a
compressed principal-toolbar icon, cramped Git content, weak tabs, and no natural
home for workspace search, history, branch workflows, or arbitrary editor splits.
The initial product scope has expanded to require those capabilities before the
first public push.

Three deliberately different interface proposals were compared: minimal native
chrome, a fully dockable workbench, and a familiar VS Code/Zed/GitHub Desktop
workbench. All converged on editor-hosted diffs, recursive splits, and one
authoritative file selection. They differed mainly on permanent navigation.

## Decision

Rafu uses one primary **Navigator** that switches between Files, Search, and
Source Control. A narrow activity strip selects the mode but never duplicates the
system sidebar toggle. The Navigator may be placed on the leading or trailing
edge. Contextual detail can appear opposite it, but Git is not permanently
confined to a right inspector.

Editor tabs, diffs, Markdown previews, and search-result previews are all editor
items hosted by recursive horizontal/vertical editor groups. File identity is
authoritative across the active tab and Files selection. The native window title
and active tab identify the file; no `.principal` toolbar icon is shown.

The default remains restrained: Files Navigator, one editor group, and no detail
pane. Power features appear when invoked.

## Alternatives considered

- Keep Files left and Git permanently right. Simple, but permanently sacrifices
  width and leaves Search/History without a coherent home.
- Fully dock every tool pane. Flexible, but too much layout machinery and choice
  for Rafu's focused premise.
- One modal Navigator with no activity strip. Most compact, but less discoverable
  for users arriving from VS Code, Zed, GitLens, and GitHub Desktop.

## Consequences

- `WorkspaceSession` needs explicit Navigator, command, restoration, and editor
  layout state rather than accumulating unrelated booleans.
- Git change clicks open titled side-by-side diff editor items.
- The prior AGENTS guidance requiring one Files/Changes container is superseded.
- Arbitrary splits require drag/drop targets, focused group routing, empty-group
  collapse, and versioned restoration.
- The activity strip is intentionally the only nonstandard permanent chrome and
  must remain visually quiet, accessible, and icon-only with tooltips.

## Revisit trigger

Revisit if measured window-width, accessibility, or usability evidence shows the
activity strip costs more clarity than it provides.

## Related material

- `docs/plans/phases/pre-initial-push-workbench.md`
- `Sources/RafuApp/Views/WorkspaceWindowView.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`

