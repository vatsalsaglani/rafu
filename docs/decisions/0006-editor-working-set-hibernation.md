# ADR 0006: Bounded editor working set with retained TextKit resources

- **Status:** Accepted
- **Date:** 2026-07-15
- **Amended:** 2026-10-17, editor lifetime repair requested by the user

## Context

Rafu's memory promise (idle workspace roughly under 150 MB) requires that
resident memory not grow with the number of *open* editor tabs, only with the
number actively in use. During the Lane 1 memory-resilience work
(`docs/plans/phases/memory-resilience.md`, lesson 8) implementing tab
hibernation surfaced a pre-existing correctness bug that reframed the whole
design.

The editor already mounted only the *selected* tab's `NSTextView`
(`EditorGroupView` rendered `EditorDocumentView` for `selectedDocument`
alone), tearing down every background tab. `EditorDocument` caches no text —
`RafuTextView.ownedTextStorage` is the sole owner of the live buffer — and
`dismantleNSView` does not save, while `load()` reads disk unconditionally.
Consequently, editing a file, switching tabs, and switching back **silently
discarded the unsaved edits**, and every tab switch reset cursor/scroll to
the top. Two reference notes asserted (as if always true) that tabs stayed
mounted to prevent exactly this; the code contradicted them.

So the memory feature and a data-safety fix are the same change: decide which
editors stay mounted (holding live text in TextKit) and which are released.

Alternatives considered:

1. **Keep every open tab mounted** (what the stale notes claimed) — safe for
   dirty buffers and scroll, but memory grows with tab count; fails the
   budget for large sessions. Rejected as the default.
2. **Release all background tabs, serialize their text into the model** — a
   document-model text cache would preserve edits, but it puts full live text
   in the model object, violating the standing invariant that
   `NSTextStorage`/TextKit owns live text. Rejected as the general mechanism.
3. **Bounded working set: keep visible ∪ dirty ∪ newest-N mounted, hibernate
   the rest; reload hibernated tabs from disk on refocus** — bounded memory,
   no data loss (dirty stays mounted so TextKit keeps its text), preserved
   scroll for recent tabs. Chosen.

## Decision

- A document retains its editor resources when it is visible in any group,
  dirty, or among the newest `N` by access order. `N = 8`
  (`DocumentHibernationPolicy.keepLoadedLimit`). Other clean documents
  hibernate and release their TextKit resources.
- `EditorDocument` owns one `@ObservationIgnored EditorResources` reference.
  The owner retains the scroll view and coordinator; the coordinator holds a
  weak document reference. Live text remains in `NSTextStorage`. Each SwiftUI
  mount receives a new host and transfers the retained scroll view into it.
  A stale host cannot update or dismantle a new host's resources.
- A structural move preserves text, undo, selection, and parser state. It does
  not load from disk or copy text into a model. Only final release or clean
  hibernation tears down the resource owner. Release is idempotent.
- **Dirty documents never hibernate.** This is the data-safety invariant,
  enforced in three layers: the policy never returns a dirty document,
  `EditorDocument.markHibernated()` is a no-op while dirty, and
  `EditorGroupView` mounts every `.loaded` document.
- Hibernated documents **reload from disk on refocus** (the authoritative
  content, since they are clean) and restore retained selection/scroll
  (`restoredSelection`/`restoredScrollFraction`, clamped, consume-once).
- Session **restoration** treats a just-restored, never-focused tab as a
  placeholder: only the visible editor per group loads content at launch; all
  other restored tabs start hibernated (the policy's grace-bypass path) and
  materialize on focus.
- **Undo is capped** at `levelsOfUndo = 200` via `undoManager(for:)`.
- `pendingDirtyText` remains a non-observed compatibility input for an initial
  load. A supplied seed takes precedence over disk and is consumed once.
  Structural moves no longer write this property.
- A `underMemoryPressure` input to the policy hibernates all eligible
  documents (drops the newest-N grace); the DispatchSource that drives it is
  wired in the caps/pressure increment, not here.

## Consequences

- The two reference notes that claimed all tabs stay mounted are corrected to
  describe the bounded working set (`docs/references/swiftui-appkit-boundary.md`,
  `docs/references/local-editor-vertical-slice.md`); the durable design lives
  in `docs/references/editor-working-set-and-hibernation.md`.
- Memory scales with the working set (≤ visible + dirty + 8), not total open
  tabs; restoring a large session loads only visible editors.
- Opening a group now mounts all its loaded tabs (hidden ones inert:
  `opacity(0)`, `allowsHitTesting(false)`, `accessibilityHidden`), a new
  one-time disk-read + git-gutter fan-out bounded by the working-set size.
- A clean guard-overridden large file can lose its highlighting override after
  hibernation. Cross-launch cursor and scroll are not persisted.
- The 2026-10-17 amendment replaces the earlier transient-snapshot decision.
  A snapshot can preserve text but cannot preserve undo or parser ownership.
  Stable resources separate the loaded-document lifetime from SwiftUI host
  lifetime while keeping the working-set bound. Keeping every editor alive
  remains rejected.

**Revisit trigger:** measure the working-set bound under many-tab use. Tune
`N` only with evidence. Remove the compatibility seed when no caller needs it.

**Related:** `docs/plans/phases/memory-resilience.md`,
`docs/plans/phases/lane-1-memory-and-syntax-plan.md` (increments 4–5);
`docs/references/editor-working-set-and-hibernation.md`;
`Sources/RafuApp/Editor/DocumentHibernationPolicy.swift`,
`Sources/RafuApp/Models/EditorDocument.swift`,
`Sources/RafuApp/Views/EditorCanvasView.swift`,
`Sources/RafuApp/Editor/CodeEditorView.swift`.
