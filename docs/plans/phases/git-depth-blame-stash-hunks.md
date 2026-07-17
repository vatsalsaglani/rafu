# Lane plan — Git depth: hunk staging, stash, blame

## Status

Implementation complete (2026-07-18; G1-G4 complete). Automated gates are green;
the keyboard-only, VoiceOver, and second-window manual acceptance passes remain
deferred after the user prohibited computer-control tooling. One of six
post-audit lanes defined in
[`post-audit-worktree-fanout.md`](post-audit-worktree-fanout.md). Runs in a
**dedicated git worktree** after its contract commit (G0) lands on main.
Hunk staging and read-only blame are explicitly enumerated Phase 6
candidates (`phase-6-controlled-expansion.md`); **stash is not on that
candidate list and needs explicit user approval before G2 starts.** All
three are covered by one ADR (0011, reserved by the fan-out plan) — hunk
staging independently justifies it as a new **write path to the index**
(`git apply --cached`) under AGENTS.md's security-review rule. Each
increment is one advisor → implementor → verification → documentor cycle.
File:line anchors reflect the tree on 2026-07-17; the repository wins when
they disagree.

## Verified baseline

- `GitService` (`Sources/RafuApp/Services/GitService.swift`) wraps
  `GitCommandRunner` (`Sources/RafuApp/Git/GitCommandRunner.swift`);
  `@concurrent` methods on a `nonisolated struct`; `checkedRun` (:454–468);
  env pins `LC_ALL=C`, `GIT_PAGER=cat`, `GIT_TERMINAL_PROMPT=0` (:108–116).
- **stdin plumbing already exists**: `GitCommandRunner.run` supports
  `standardInput: Data?` (:52–58) — exactly what patch application needs.
- Diff model (`Sources/RafuApp/Models/GitModels.swift`): `GitDiffScope`
  (:156–161), `GitDiffHunk` (:201–209, ordinal `id`), `GitFileDiff`
  (:211–220) carries **`rawPatch`** = exact git stdout.
  `UnifiedDiffParser` **discards `\ No newline at end of file`**
  (`UnifiedDiffParser.swift:31–34`) — aligned rows are lossy; `rawPatch`
  is not. This decides the patch-construction strategy.
- Diff UI: `GitSideBySideDiffView.hunkHeader`
  (`EditorCanvasView.swift:797–812`) is the natural Stage/Unstage home.
  **`GitOpenDiff` (`GitWorkbenchModels.swift:16–28`) does not carry the
  originating `GitDiffScope`** — the gap G0 closes.
- Source Control panel: `GitInspectorView.swift` `changesView` (:215–266),
  merge `confirmationDialog` pattern (:58–71). Stage/unstage:
  `WorkspaceSession.setStaged` (:1326–1346) → `GitService.setStaged`
  (:150–197).
- Editor gutter markers flow read-only via `gutterLineChanges`
  (`WorkspaceSession.swift:1541–1560`); blame deliberately does **not**
  touch that path (see G3).
- Confirmed absent: no `stash`, `blame`, or `git apply` code anywhere.
- Test harness: `GitServiceTests.swift` `withRepository { root in … }`
  temp-repo pattern — the round-trip fixture harness to reuse.

## Global rules for this lane

- **Owned paths:** `Sources/RafuApp/Git/**`,
  `Sources/RafuApp/Services/GitService.swift`,
  `Sources/RafuApp/Views/GitInspectorView.swift`,
  `Tests/RafuAppTests/GitServiceTests.swift`, new
  `GitHunkPatchBuilderTests.swift` / `GitStashParserTests.swift` /
  `GitBlameParserTests.swift`, `docs/decisions/0011-*.md` (reserved
  number), `docs/references/` git note additions, and this plan document.
- **Shared — contract-first or land-last:**
  `Sources/RafuApp/Models/WorkspaceSession.swift` and
  `Sources/RafuApp/Git/GitWorkbenchModels.swift` change **only in G0**
  (before fan-out); `Sources/RafuApp/Models/GitModels.swift` additive
  model types only; `Sources/RafuApp/Views/EditorCanvasView.swift` (hunk
  button + blame canvas — coordinate with any lane touching it);
  `Sources/RafuApp/App/RafuAppCommands.swift` and
  `Sources/RafuApp/Views/CommandPaletteView.swift` land in the final
  increment per the fan-out shared-file protocol.
- **Forbidden paths:** `Sources/RafuApp/LanguageIntelligence/**`,
  `Sources/RafuApp/Editor/**` — including `CodeEditorView.swift` and
  `EditorGutterRulerView.swift` (blame intentionally avoids the gutter to
  avoid this contention), `Sources/RafuApp/Markdown/**`,
  `Sources/RafuCLI/**`, `Sources/RafuCore/**`, `Package.swift`,
  `AGENTS.md`, shared doc indexes (appends at merge).
- Invariants: `/usr/bin/git` + argument arrays only; bounded, cancellable
  capture; no persistent git process; no auto-stash anywhere; no
  color-only signalling; explicit user action for every write; blame data
  bounded to the focused file and discarded on close.
- New `@concurrent` service methods and apply-then-refresh sequencing take
  the `swift-concurrency-pro` review path. Index-write and stash-write
  paths take the AGENTS.md security review.
- Verification per increment: `swift test --filter Git` then full
  `swift test`; `swift build`; format fix+lint;
  `./script/build_and_run.sh --verify` after UI changes (G1, G2, G3) —
  never while another lane runs it.
- After each green increment the coordinator stops and asks the user to
  commit. No agent commits.

## G0 — Contract commit (lands on MAIN before worktree fan-out)

- `GitWorkbenchModels.swift`: add `let scope: GitDiffScope` to
  `GitOpenDiff`; thread through the two producers
  (`gitOpenChangeDiff` `WorkspaceSession.swift:1379`,
  `gitOpenHistoryDiff` :1424).
- `WorkspaceSession`: add the new observable git state (stash list, blame
  document, hunk-busy flag) and stub async action methods (stored
  observable properties cannot live in an extension — this is why the
  slice lands first).
- Build + full suite green; zero behavior change. **User commits; other
  lanes rebase onto this.**

## G1 — Hunk staging (first: highest leverage, reuses everything)

- New pure `Sources/RafuApp/Git/GitHunkPatchBuilder.swift`: slice
  **`rawPatch`** (never reconstruct from aligned rows): prologue = lines
  before the first `@@` (`diff --git…`, `index…`, `--- a/…`, `+++ b/…`);
  block = the i-th `@@` section up to the next `@@`/`diff --git`/end;
  `\ No newline at end of file` preserved verbatim. Designed to accept a
  `rows:` subset later (line-range staging is a documented follow-up, not
  v1).
- `GitService.applyHunk(patch:staging:at:)` →
  `checkedRun(["apply","--cached"] + (staging ? [] : ["--reverse"]) +
  ["-"], standardInput: Data(patch.utf8))`. No `--3way`, no `--recount`
  (they mask context drift). Nonzero exit → friendly "file changed since
  this diff was captured" error + re-diff.
- Session: `stageHunk`/`unstageHunk` → apply → `refreshGit()` → re-fetch
  the same-scope diff (close if empty). Guard on `isGitBusy`.
- UI: `hunkHeader` (:797–812) trailing "Stage Hunk"/"Unstage Hunk" button
  keyed off `GitOpenDiff.scope` (`.workingTree`/`.staged` only; hidden for
  `.commit`/`.between`/binary), + context menu. Menu command deferred to
  the final shared-file increment. **Scope restriction: modified files
  only** — added/deleted/renamed/untracked/binary fall back to whole-file
  staging (documented).
- Tests: builder fixtures (single hunk, middle-of-three, no trailing
  newline); `withRepository` round-trip — stage one hunk of a multi-hunk
  file → `git diff --cached` shows exactly that hunk → unstage → index
  clean. **Authoritative check** for the overlapping-partially-staged-
  region case the advisor could not resolve read-only: if flaky, narrow
  v1 to whole-hunk staging of fully-unstaged files.

## G2 — Stash (**requires explicit user approval first** — not a phase-6 candidate)

- New pure `GitStashParser` + `GitStashEntry { index, selector, message,
  createdAt, branch? }`; list via `git stash list -z
  --format=%gd%x1f%ct%x1f%gs`.
- Service: `stashList`, `stashPush(message:includeUntracked:)`,
  `stashApply(index:)`, `stashPop(index:)`, `stashDrop(index:)` — the ref
  is always `stash@{n}` built from a validated non-negative Int; **never
  interpolate user text into a ref**. Drop (and pop-that-discards)
  require a `confirmationDialog` (mirror `GitInspectorView.swift:58–71`).
- UI: collapsible "Stashes" section in `changesView` + "Stash Changes…"
  sheet (message + include-untracked toggle). `refreshGit` loads the
  cheap stash list. Handle "No local changes to save" gracefully.
- Tests: parser (zero/one/many, WIP-vs-`On branch` subjects); round-trip
  push (tree clean, count 1) → apply (restored) → drop (empty).

## G3 — Blame (read-only, editor-hosted canvas)

- New pure `GitBlameParser` + `GitBlame`/`GitBlameLine { lineNumber,
  commitID, shortID, author, time, summary, isBoundary }`; parse
  `git blame --porcelain -- <path>` with a SHA-keyed metadata cache
  (porcelain dedups headers — smaller output than `--line-porcelain`).
- `GitService.blame(forRelativePath:at:)` — one bounded invocation,
  `maximumOutputBytes` capped.
- Presentation: a **read-only editor-hosted blame canvas** analogous to
  `GitStandaloneDiffCanvas` (`EditorCanvasView.swift:626–648`), driven by
  an ephemeral session field, opened/closed like a diff. Authorship is a
  leading text annotation column — not gutter color — honoring "reserve
  color for meaning." Deliberately avoids `EditorGutterRulerView`/
  `CodeEditorView` (editor-lane files); the gutter-annotation alternative
  is recorded in ADR 0011 as rejected-for-MVP.
- Tests: two-commit fixture (per-line SHAs/authors), boundary commit,
  header-dedup reuse; round-trip in `withRepository`. Closing discards
  the data (no retained state).

## G4 — Shared-file commands + documentation close-out

- `RafuAppCommands` + `CommandPaletteView.makeCommands()`: Stage/Unstage
  Hunk, Stash Changes, Blame File entries (coordinate with the fan-out
  integration owner — multi-cursor and IPC lanes also append here).
- ADR 0011: one mini-RFC covering all three (user need,
  process/memory/security cost, the new index write path, no-auto-stash,
  stash's off-candidate-list approval, blame canvas-vs-gutter,
  removability).
- Reference note (extend `git-process-and-parsing.md` or sibling): the
  `git apply --cached [--reverse]` stdin contract, rawPatch-slicing
  rationale (`\ No newline` hazard), stash ref validation, blame
  porcelain parsing + bounds.
- Manual pass: stage/unstage a hunk and confirm with external
  `git status`/`git diff --cached`; keyboard-only + VoiceOver on the new
  controls; second window; blame open/close leaves no retained state.

## Risks

- **Context drift**: `git apply --cached` fails atomically on mismatch —
  surface + re-diff; never `--3way`.
- **No-trailing-newline corruption** if patches were rebuilt from rows —
  prevented by rawPatch slicing.
- Stash ref injection — prevented by Int-validated selectors.
- Blame memory — bounded, focused-file-only, discarded on close;
  `LC_ALL=C` does not corrupt UTF-8 author bytes.
- Prefer not touching `GitDiffHunk` at all (rawPatch slicing avoids it);
  if any model gains fields, keep `Sendable`/`Hashable`.

## Exit

- Hunk stage/unstage from the diff view (button, context menu, menu
  command) with exact-index verification and drift-safe failure.
- Stash list/push/apply/pop/drop, drop confirmed, no auto-stash —
  **only if the user approved G2**.
- Blame read-only, bounded, canvas-hosted, color-honest.
- ADR 0011 + reference note landed; all parsers pure with fixture tests;
  round-trips green in temp repos; full suite + `--verify` green.

## Completion record

- **G1 — complete (2026-07-17):** exact `rawPatch` hunk slicing, stdin-only
  `git apply --cached [--reverse] -`, modified-file-only canvas controls, stale
  context failure, and apply/refresh/re-diff session sequencing landed. The
  overlapping-partially-staged fixture passed without narrowing v1: the selected
  line-4 hunk alone entered the index, the distant line-20 hunk stayed in the
  working tree, reverse apply returned the index to empty, and both working-tree
  changes remained. Verification: 31 Git-focused tests, 519 full tests, `swift
  build`, and format fix/lint green. Test delta: +4 (three pure builder fixtures,
  one repository round-trip). `build_and_run.sh --verify` and manual UI checks
  remain intentionally consolidated at G4.
- **G2 — complete (2026-07-18):** user-approved explicit stash push (optional
  message and include-untracked toggle), list/apply/pop/drop operations,
  canonical non-negative `stash@{n}` validation, stale-entry preflight, and
  confirmation for pop/drop landed with a GitLens-style collapsible Source
  Control section. No auto-stash path exists. Because the G0 contract freezes
  `WorkspaceSession.refreshGit()` outside the four stash stub bodies, a small
  owned `GitStashCoordinator` performs initial and user-requested list refresh;
  stash mutations refresh their own list. This intentionally deviates from the
  stale G2 anchor while preserving its refresh intent and the hard G0 boundary.
  Verification: 38 Git-focused tests, 526 full tests, `swift build`, and format
  fix/lint green. Test delta: +7 (five pure parser fixtures and two service
  tests, including the tracked+untracked push/apply/drop repository round-trip).
  `build_and_run.sh --verify` and manual UI checks remain consolidated at G4.
- **G3 — complete (2026-07-18):** one bounded, cancellable
  `git blame --porcelain -- <path>` process now parses per-line commit, author,
  time, summary, and boundary metadata with a full-object-ID cache for Git's
  deduplicated headers. The focused saved file opens as an editor-hosted,
  read-only attribution table with textual root markers, a keyboard/VoiceOver
  reachable close control, and no gutter or `Editor/**` changes; selection and
  workspace changes discard it. G0 froze `GitBlame` as metadata-only and this
  lane may add model types but not alter that contract, so the canvas presents
  line/author/commit/age/summary rather than retaining source text in SwiftUI.
  This is an intentional repository-over-stale-anchor deviation that preserves
  line attribution, bounded memory, and the rejected-gutter decision. Verification:
  42 Git-focused tests, 530 full tests, `swift build`, and format fix/lint green.
  Test delta: +4 (three pure porcelain fixtures and one two-author repository
  round-trip). `build_and_run.sh --verify` and manual UI checks remain
  consolidated at G4.
- **G4 — complete (2026-07-18):** minimal additive menu and command-palette
  entries expose Stage/Unstage Hunk, conservative tracked-only Stash Changes,
  and Blame File without claiming shared keyboard shortcuts. ADR 0011 records
  the user-approved stash expansion, exact index-write contract, bounded blame
  canvas, rejected-for-MVP gutter alternative, and removability; the Git
  process reference records the verified parsing and security contracts. Test
  delta: +0. Final automated evidence: 42 Git-focused tests, 530 full tests,
  `swift build`, format fix/lint, and `build_and_run.sh --verify` green. The G1
  repository round-trip supplies the external `git diff --cached`/working-tree
  evidence for exact stage/unstage behavior. Keyboard-only, VoiceOver, and
  second-window checks are not claimed: they remain manual acceptance work
  because the user explicitly disallowed computer-control tooling during the
  consolidated pass.
