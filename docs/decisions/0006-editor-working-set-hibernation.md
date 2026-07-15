# ADR 0006: Bounded editor working set with hibernation and transient dirty-text snapshots

- **Status:** Accepted
- **Date:** 2026-07-15

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

- A document's editor stays **mounted** (its `NSTextStorage` lives) when the
  document is visible in any group, **or** dirty, **or** among the newest
  `N` by access order. `N = 8` (`DocumentHibernationPolicy.keepLoadedLimit`).
  All other documents **hibernate**: their editor is unmounted, exactly as
  the pre-existing behavior, so hibernation adds no memory over the old
  aggressive teardown.
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
- **One sanctioned exception to the "text lives only in TextKit" invariant:**
  `EditorDocument.pendingDirtyText` — a transient, non-observed, dirty-only
  buffer snapshot captured in `dismantleNSView` and consumed by `load()` in
  place of the disk read. It exists solely because a *structural* layout
  change (group split, cross-group tab move) replaces an `AnyView` subtree
  and destroys the `NSView` regardless of `loadState`, so keeping-mounted
  cannot preserve the buffer there. It is cleared immediately on restore and
  never used for clean documents.
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
- Known limitations: a purely theoretical double-structural-remount race
  within one guard-decision async gap (harmless — snapshot text is identical
  across an automated remount); a clean guard-overridden large file loses its
  "Enable Highlighting" override after hibernation (banner reappears; dirty
  files unaffected); cross-launch cursor/scroll is not persisted, so restored
  tabs materialize at top-of-file on first focus.

**Revisit trigger:** if the working-set bound (`N = 8`) proves wrong under
real many-tab use, tune the constant, not the model; if structural remounts
become avoidable (stable layout identity without `AnyView` erasure), the
`pendingDirtyText` exception can be removed.

**Related:** `docs/plans/phases/memory-resilience.md`,
`docs/plans/phases/lane-1-memory-and-syntax-plan.md` (increments 4–5);
`docs/references/editor-working-set-and-hibernation.md`;
`Sources/RafuApp/Editor/DocumentHibernationPolicy.swift`,
`Sources/RafuApp/Models/EditorDocument.swift`,
`Sources/RafuApp/Views/EditorCanvasView.swift`,
`Sources/RafuApp/Editor/CodeEditorView.swift`.
