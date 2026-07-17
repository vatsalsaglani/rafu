# Post-audit worktree fan-out — six lanes, pairwise merge

## Status

Planned (2026-07-17). This is the coordination contract for the six lanes
identified by the 2026-07-17 project-status audit. It owns: fan-out
prerequisites, contract-first commits, lane ownership boundaries, ADR
number reservations, the shared-file protocol, and the merge/test
protocol back into `main`. Individual scope, increments, and precise
edits live in each lane's plan document — this file never overrides them.

## The six lanes

| Lane | Plan document | Suggested branch | Primary owned area |
|---|---|---|---|
| L1 LSP production readiness | [`lsp-production-readiness.md`](lsp-production-readiness.md) | `lane/lsp-readiness` | `Sources/RafuApp/LanguageIntelligence/**` |
| L2 Symbol coverage + markdownInline | [`symbol-coverage-and-markdown-inline.md`](symbol-coverage-and-markdown-inline.md) | `lane/symbol-coverage` | `Resources/Grammars/**`, `Editor/Syntax/**`, `WorkspaceSymbolExtractor` |
| L3 Mermaid preview honesty | [`mermaid-preview-honesty.md`](mermaid-preview-honesty.md) | `lane/mermaid-honesty` | `Sources/RafuApp/Markdown/**` |
| L4 Multi-cursor editing | [`multi-cursor-editing.md`](multi-cursor-editing.md) | `lane/multi-cursor` | `RafuTextView`, `CodeEditorView`, new `MultiCaret*` |
| L5 Git depth (hunks/stash/blame) | [`git-depth-blame-stash-hunks.md`](git-depth-blame-stash-hunks.md) | `lane/git-depth` | `Sources/RafuApp/Git/**`, `GitService`, `GitInspectorView` |
| L6 CLI ↔ app IPC v1 | [`cli-app-ipc.md`](cli-app-ipc.md) | `lane/cli-ipc` | `RafuCore/Launcher/IPC/**`, `RafuApp/Launcher/**`, `RafuCLI` |

Every lane: one worktree, one agent/coordinator, advisor → implementor →
verification → documentor per increment, user commits after each green
increment, no agent commits or pushes.

## Prerequisites (strictly ordered, all on `main`, all user-committed)

1. **Land the current working tree.** The checkout carries substantial
   uncommitted work (CLI locator/installer fix, staging-symlink installer
   fix, memory/index work, docs). No worktree is created until `git
   status` is clean. (Independently: the Node-checksum commit `57a8dbc`
   is still unpushed; shipping the pending `v0.1.2-beta` first remains
   recommended but is not a fan-out blocker.)
2. **Commit these six lane plans + this fan-out plan + the phases README
   row** (documentation-only commit).
3. **Contract commit G0** (Git lane; see its plan): `GitOpenDiff.scope` +
   `WorkspaceSession` git-state stubs. Build + full suite green.
4. **Contract commit I0** (IPC lane; see its plan): `RafuCore` IPC
   protocol/framing types, `WorkspaceSession` goto seam signature,
   `WorkspaceWindowRegistry` + `WorkspaceSceneRoot` hooks, server stub
   start/stop. Build + full suite green.

G0 and I0 both touch `WorkspaceSession.swift` — they land **serially on
main, before any worktree exists**, which is exactly why they are pulled
out of their lanes. After I0, `WorkspaceSession.swift`,
`WorkspaceSceneRoot.swift`, and `ExternalOpenRequests.swift` are frozen
for all six lanes (exception: L4's MC5 additive session methods, which
land through the integration owner at merge time).

5. **Create the six worktrees** from the post-I0 commit:
   `git worktree add ../rafu-<lane> -b lane/<name>`.

## ADR number reservations (avoids cross-lane collisions)

| ADR | Lane | Subject |
|---|---|---|
| 0008 | L3 | Native bounded Mermaid renderer + honest fallback; shared-WKWebView option deferred |
| 0009 | L6 | CLI ↔ app versioned same-user Unix-domain socket protocol |
| 0010 | L1 | npm transitive-dependency supply chain + checksum-source policy |
| 0011 | L5 | Advanced Git: index write path (hunk staging), stash approval, blame presentation |

ADR files are authored inside their lanes; the `docs/decisions/README.md`
index rows are appended by the integration owner at merge time.

## Shared-file protocol

- **`Package.swift` / `Package.resolved`** — no lane may touch them. Any
  apparent need is an escalation to the user.
- **`WorkspaceSession.swift`** — frozen after G0/I0 (above).
- **`RafuAppCommands.swift` and `CommandPaletteView.swift`** — the three
  lanes that add commands (L4 MC5, L5 G4, L2 increment C's one-line
  guard) keep those edits in their **final** increment. At merge time the
  integration owner lands them as small additive hunks, one lane at a
  time. A lane must not block its core work on these files.
- **`EditorCanvasView.swift`** — L5 only (hunk button + blame canvas).
  L4 does not touch it; L3 does not touch it.
- **Shared doc indexes** (`docs/references/README.md`,
  `docs/decisions/README.md`, `docs/plans/phases/README.md`) — lanes
  write their notes/ADRs as files but do **not** edit the indexes; the
  integration owner appends index rows at each merge. This removes the
  most common trivial conflict.
- **`AGENTS.md`, `CLAUDE.md`** — integration-owned, untouched by lanes.
- **`./script/build_and_run.sh --verify`** kills any running staged
  Rafu.app — only one lane (or the integration owner) runs it at a time;
  coordinate through the user when lanes run concurrently.

Ownership disjointness (verified against the six plans): L1 =
LanguageIntelligence only; L2 = Grammars/Editor-Syntax/extractor (+ the
palette guard); L3 = Markdown only; L4 = RafuTextView/CodeEditorView/
EditorDocument-additive; L5 = Git/GitService/GitInspectorView (+
EditorCanvasView); L6 = RafuCore-IPC/RafuApp-Launcher/RafuCLI. No two
lanes own the same file outside the land-last shared hunks above.

## Merge protocol (two at a time, then test on `main`)

Trigger: the user tells the main-checkout coordinator which lanes are
complete (each lane's own exit checklist green first). Default pairing —
ordered by conflict surface, but **completion order wins** when it
diverges; the invariant is "one merge at a time, full gates between, two
merges per integration round":

- **Round 1 — L3 (Mermaid) + L1 (LSP readiness).** Zero path overlap
  with each other or anyone else; safest first round.
- **Round 2 — L2 (Symbols) + L4 (Multi-cursor).** Both Editor-adjacent
  but file-disjoint; the round lands L4's MC5 command hunks and L2's
  palette guard via the integration owner.
- **Round 3 — L5 (Git) + L6 (IPC).** Heaviest shared surface; their
  WorkspaceSession contracts are already on `main` (G0/I0), so the
  remaining risk is the land-last command hunks.

Per merge (each lane, sequentially within a round):

1. In the lane worktree: sync with `main`
   (`git merge main` or rebase per user preference), resolve, re-run the
   lane's own gates.
2. On `main`: merge the lane branch (no squash decision is made here —
   user's call at merge time).
3. Gates: `swift build` (clean, no new warnings), full `swift test`,
   `./script/format.sh --lint`.
4. Integration owner appends this lane's doc-index rows and (if this
   round carries them) its command/palette hunks; re-run the gates.

Per round (after its second merge):

5. `./script/build_and_run.sh --verify` plus the round's manual spot
   checks: R1 — Markdown preview fallback/badge + a live LSP smoke
   (P5 checklist subset); R2 — multi-caret gesture checklist subset +
   `@`/`#` symbol modes; R3 — hunk stage/unstage round-trip + the
   nine-item IPC end-to-end checklist.
6. Second-window pass and a `ProcessResourceRegistry`/idle-RSS sanity
   glance (budget ~150 MB idle).
7. User commits the integration round; only then does the next round
   start.

Worktrees are removed (`git worktree remove`) after their round's gates
hold on `main`.

## Cross-lane approvals and open decisions (user calls)

- **L5/G2 stash** is not on the phase-6 candidate list — explicit user
  approval required before that increment starts (recorded in ADR 0011).
- **L1/ADR 0010** npm supply-chain policy — decide before
  typescript-language-server is advertised as runnable.
- **L2 increment C** go-to-definition kind-filter (config keys/headings
  answering ⌃⌘J) — resolve or explicitly defer at merge.
- **L4/MC5 shortcuts** (⌘D, ⌥⌘↑/↓) — conflict check against the full
  command map before landing.
- **L6** `--wait` deferral to v2 and JSON-for-local-IPC are recorded in
  ADR 0009; objections surface there.

## Exit

All six lanes merged; three integration rounds green (build, full suite,
lint, `--verify`, manual spot checks, second-window pass); ADRs
0008–0011 and every lane's reference notes indexed; each lane's plan
document carries its completion record; no `Package.*` drift; idle-RSS
budget still holds. Follow-ups that remain open by design: `--wait` v2,
line-range staging, persistent-injection markdown model, the deferred
shared-WKWebView Mermaid option, and Release-build p95/RSS measurement
evidence (owed since lane 1).
