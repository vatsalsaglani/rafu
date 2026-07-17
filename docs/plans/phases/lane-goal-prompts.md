# Goal-mode prompts for the six post-audit lanes

Paste one prompt per Claude Code / Codex session, each running in its own
worktree. The lane plan documents are the contracts; these prompts are
the goal wrappers.

## Before you paste anything (main checkout, in order)

1. Commit the current working tree (it must be clean before fan-out).
2. Commit the seven plan docs + this file + the phases README row.
3. Land contract commits **G0** (Git lane plan) and **I0** (IPC lane
   plan) serially on `main` — integration-owner work in the main
   checkout, not part of any lane prompt.
4. Create the worktrees from the post-I0 commit:

```bash
git worktree add ../rafu-lsp-readiness   -b lane/lsp-readiness
git worktree add ../rafu-symbol-coverage -b lane/symbol-coverage
git worktree add ../rafu-mermaid         -b lane/mermaid-honesty
git worktree add ../rafu-multi-cursor    -b lane/multi-cursor
git worktree add ../rafu-git-depth       -b lane/git-depth
git worktree add ../rafu-cli-ipc         -b lane/cli-ipc
```

Shared conventions baked into every prompt: agents commit on their own
lane branch after each green increment (pre-authorized by issuing the
goal) but never push, never merge, never touch `main`; nobody edits the
shared doc indexes (`docs/references/README.md`,
`docs/decisions/README.md`, `docs/plans/phases/README.md`) — intended
index rows go in the final report; `./script/build_and_run.sh --verify`
is deferred to each lane's final increment because the script kills the
one shared staged app and the lanes run concurrently.

---

## Prompt 1 — LSP production readiness (`../rafu-lsp-readiness`)

```
/goal You are the coordinator for the LSP-production-readiness lane of
Rafu's post-audit fan-out, running in the dedicated worktree on branch
lane/lsp-readiness. First run `git status --short --branch`; if you are
not on that branch with a clean tree, STOP and report.

Read first, in order:
1. AGENTS.md
2. docs/plans/phases/post-audit-worktree-fanout.md (shared-file
   protocol, ADR reservations)
3. docs/plans/phases/lsp-production-readiness.md — YOUR CONTRACT: its
   increments P1-P5, owned/forbidden paths, gates, and risks govern this
   run. If the repository disagrees with a file:line anchor in it, the
   repository wins — note the deviation, never weaken the intent.
4. docs/references/navigation-and-lsp-contracts.md,
   docs/references/language-server-install-staging.md,
   docs/decisions/0005-language-intelligence-and-lsp.md

Execute increments P1, P2, P3, P4, P5 strictly in order, one
advisor → implementor → verification → documentor cycle each:
1. Send the increment text (verbatim from the plan) plus prior-increment
   findings to the `advisor` agent; wait for its brief.
2. Review the brief against the plan and AGENTS.md; resolve open
   questions yourself using "Decisions pre-resolved" below — never wait
   for user input.
3. Send increment text + full advisor brief + your corrections to the
   `implementor` agent.
4. Independently verify — never trust self-reports: swift build (clean,
   no new warnings); full swift test (all offline — every new test uses
   FixtureAssetDownloader / fake resolver / in-memory transport);
   ./script/format.sh --fix then --lint. Defer build_and_run.sh --verify
   to the end of P2's consent-UI work or the final pass; list deferred
   GUI checks in the report.
5. When green, run the `documentor` agent for the increment's notes and
   ADR 0010 — write the note/ADR FILES but do NOT edit any shared doc
   index; record intended index rows in your final report.
6. Commit on THIS branch with a message naming the increment. Never
   push, never merge, never touch main.
7. Move immediately to the next increment.

Hard rules:
- Owned/forbidden paths exactly as the plan's Global rules. Audit
  `git diff --stat` before every commit; zero forbidden-path diffs.
  WorkspaceSession.swift, Views/, Navigation/, Package.swift/
  Package.resolved must remain byte-identical.
- No @unchecked Sendable. Never log URLs, npm arguments, document text,
  or server payloads. P1 and P2 take the swift-concurrency-pro review
  path and the AGENTS.md security review.

Decisions pre-resolved for this run:
- ADR 0010 (write status Proposed): accept unpinned npm transitive fetch
  WITH mitigations (--ignore-scripts, --omit=dev, consent disclosure) as
  the recorded default; also record the checksum policy as
  locally-computed SHA-256 pin (trust-on-first-download). The user flips
  to Accepted at merge.
- P4 constants: if this environment has network access, run the P4
  verification procedure yourself (curl + shasum -a 256, packument
  cross-check, license check) and fill the real constants; if not, leave
  them gated and record exactly what remains for the human.
- P5: run every headless part; defer GUI steps to the merge round and
  list them.

Stop only when P1-P5 are complete and verified, or on a genuine blocker
(report it precisely). Finish with ONE consolidated report: per
increment — changes, files, test delta, deviations, verification
evidence; then intended doc-index rows, deferred GUI checks, remaining
risks, and the plan's exit checklist status.
```

---

## Prompt 2 — Symbol coverage + markdownInline (`../rafu-symbol-coverage`)

```
/goal You are the coordinator for the symbol-coverage lane of Rafu's
post-audit fan-out, running in the dedicated worktree on branch
lane/symbol-coverage. First run `git status --short --branch`; if you
are not on that branch with a clean tree, STOP and report.

Read first, in order:
1. AGENTS.md
2. docs/plans/phases/post-audit-worktree-fanout.md
3. docs/plans/phases/symbol-coverage-and-markdown-inline.md — YOUR
   CONTRACT: increments A-E, owned/forbidden paths, gates. Repository
   wins over stale file:line anchors; note deviations, keep intent.
4. docs/references/tree-sitter-highlighting.md,
   docs/references/workspace-symbol-index.md

Execute increments A, B, C, D, E STRICTLY SERIALLY (each mutates the two
pinned negative-test files), one advisor → implementor → verification →
documentor cycle each, following the same 7-step cycle as the plan
prescribes: advisor brief → your critical review → implementor →
independent verification (swift build; full swift test;
./script/format.sh --fix then --lint) → documentor (note files only,
never shared doc indexes) → commit on this branch → next increment.
Run `swift build` once at the start so .build/checkouts is populated,
and verify EVERY query node/field name against the grammar's
src/node-types.json BEFORE the implementor writes a tags.scm — a wrong
node name fails silently (tagsQuery caches nil). Every new grammar gets
a tagsQuery-non-nil + patternCount>0 assertion AND a real-extraction
fixture test. Defer build_and_run.sh --verify to increment D's final
pass (other lanes share the staged app); list deferred GUI checks.

Hard rules:
- Owned/forbidden paths exactly as the plan. Package.swift/
  Package.resolved byte-identical (both grammars already packaged).
  LanguageIntelligence/, Markdown/ (preview), Git services, RafuCLI —
  forbidden. The CommandPaletteView edit is ONE line (the increment-C
  markdown guard), isolated in its own commit and flagged in the report.
- Increment D touches SyntaxParsingActor → swift-concurrency-pro review
  path (inline parser/tree actor-confined; nothing non-Sendable crosses
  await; teardown releases the inline parser). No @unchecked Sendable.
- Pinned tests (GrammarRegistryTests:133-152,
  WorkspaceSymbolIndexTests:39,48-50) flip in lockstep with each
  increment — the suite must never be left red between commits.

Decisions pre-resolved for this run:
- Go-to-definition kind filter: RESTRICT .definition/.declaration
  matching to code-declaration kinds (function/method/class/interface/
  property/constant/module); sections/keys surface only in # search.
  Record the decision + rationale in workspace-symbol-index.md.
- JSON: deliberately no tags.scm; document the skip in Grammars/README.
- markdownInline: the bounded lazy visible-range design from the plan;
  the persistent-injection alternative stays documented-deferred.

Stop only when A-E are complete and verified, or on a genuine blocker.
Finish with ONE consolidated report: per increment — changes, files,
test delta, deviations, evidence; then intended doc-index rows, deferred
GUI checks (staged-app Markdown coloring pass, @/# manual pass), and
the plan's exit checklist status.
```

---

## Prompt 3 — Mermaid preview honesty (`../rafu-mermaid`)

```
/goal You are the coordinator for the Mermaid-preview-honesty lane of
Rafu's post-audit fan-out, running in the dedicated worktree on branch
lane/mermaid-honesty. First run `git status --short --branch`; if you
are not on that branch with a clean tree, STOP and report.

Read first, in order:
1. AGENTS.md (especially the Markdown/WKWebView invariants)
2. docs/plans/phases/post-audit-worktree-fanout.md
3. docs/plans/phases/mermaid-preview-honesty.md — YOUR CONTRACT:
   increments M1-M7, owned/forbidden paths, preserved contracts, gates.
   Repository wins over stale anchors; note deviations, keep intent.
4. docs/references/local-editor-vertical-slice.md,
   docs/references/editor-dependencies.md

Execute increments M1, M2, M3, M4, M5, M6, M7 strictly in order, one
advisor → implementor → verification → documentor cycle each (advisor
brief → your critical review → implementor → independent verification:
swift build; full swift test; ./script/format.sh --fix then --lint →
documentor → commit on this branch → next). The lane is deliberately
shippable after ANY increment — never let a commit land red. Defer
build_and_run.sh --verify to one consolidated GUI pass at M6/M7 (other
lanes share the staged app); the pass must cover: directional flowchart
with subgraphs + edge labels, sequence with alt/loop + activations, an
unsupported type falling back to code-block + notice, the "Simplified
native preview" badge, a second window, and Reduce Motion.

Hard rules:
- Owned paths: Sources/RafuApp/Markdown/** + the named tests + ADR 0008
  + the lane's reference note + the 3-line Mermaid sentence in
  local-editor-vertical-slice.md + the plan doc. Everything else in the
  plan's forbidden list stays byte-identical — especially Package.*,
  RafuTheme.swift (NO new theme tokens; use warning/info with
  textSecondary fallback), Editor/, LanguageIntelligence/.
- Preserved contracts: MarkdownUI boundary,
  TreeSitterCodeSyntaxHighlighter routing, the MarkdownPreviewSegment
  parser regex/contract, durable UUID identity on every repeated row
  (never offsets/content hashes). All new model/layout types are
  nonisolated Sendable value types; layout is never computed per-frame
  in a Canvas closure.
- No pixel-snapshot harness — layout tests assert ranks/containment/
  no-overlap frame invariants only.

Decisions pre-resolved for this run:
- M1 result-shape (one MermaidParseResult enum vs extending Kind):
  implementor's choice, recorded in the plan's M1 completion note.
- ADR 0008: author with status Proposed (the user flips to Accepted at
  merge); the deferred shared-WKWebView option and its reopen criteria
  must be recorded exactly as the plan's Decision section states.
- Unsupported-type keyword list: take from current Mermaid docs at
  implementation time; unknown/empty header → .malformed.

Do NOT edit shared doc indexes; record intended index rows in the final
report. Stop only when M1-M7 are complete and verified, or on a genuine
blocker. Finish with ONE consolidated report: per increment — changes,
files, test delta, deviations, evidence; then intended index rows,
deferred GUI checks, and the plan's exit checklist status.
```

---

## Prompt 4 — Multi-cursor editing (`../rafu-multi-cursor`)

```
/goal You are the coordinator for the multi-cursor lane of Rafu's
post-audit fan-out, running in the dedicated worktree on branch
lane/multi-cursor. First run `git status --short --branch`; if you are
not on that branch with a clean tree, STOP and report.

Read first, in order:
1. AGENTS.md
2. docs/plans/phases/post-audit-worktree-fanout.md
3. docs/plans/phases/multi-cursor-editing.md — YOUR CONTRACT:
   increments MC1-MC6, verified baseline, owned/forbidden paths, gates.
   Repository wins over stale anchors; note deviations, keep intent.
4. docs/references/swiftui-appkit-boundary.md,
   docs/references/editor-search-and-restoration.md (undo grouping),
   docs/references/editor-working-set-and-hibernation.md

Execute increments MC1, MC2, MC3, MC4, MC5, MC6 strictly in order, one
advisor → implementor → verification → documentor cycle each (advisor
brief → your critical review → implementor → independent verification:
swift build; FULL swift test — the single-caret editor tests are the
regression canary and must stay green untouched; ./script/format.sh
--fix then --lint → documentor → commit on this branch → next).

MC2 starts with the two spikes: Spike A (does setSelectedRanges retain
multiple zero-length ranges with a blinking primary caret?) and Spike B
(overlay subview vs drawInsertionPoint override). Resolve them with the
best evidence available headlessly (a small test harness against
NSTextView where possible); if a spike genuinely requires interactive
GUI observation, choose the overlay-owned design (correct under either
spike outcome, per the plan's risk section), proceed, and flag the
unconfirmed spike in the report. Defer build_and_run.sh --verify and
the manual gesture checklist to one consolidated pass at MC6.

Hard rules:
- Owned/forbidden paths exactly as the plan. Editor/Syntax/** is
  forbidden (the reparse contract is consumed unchanged); Package.*
  byte-identical. CodeEditorView/EditorDocument edits are additive
  hunks only.
- MC5's RafuAppCommands + WorkspaceSession hunks are the ONLY shared-
  file edits: keep them minimal, additive, in ONE isolated commit,
  flagged in the report for the integration owner. Before writing them,
  grep RafuAppCommands for shortcut collisions.
- Every override bails to super at <=1 caret or hasMarkedText() — the
  single-caret path stays byte-for-byte unchanged. One multi-edit = one
  undo group, setActionName BEFORE endUndoGrouping. No @unchecked
  Sendable.

Decisions pre-resolved for this run:
- Shortcuts: ⌘D select-next-occurrence, ⌘⇧L select-all, ⌥⌘↑/⌥⌘↓ add
  caret above/below, Esc collapse — unless the collision grep says
  otherwise; if it does, pick the nearest free alternative and record.
- Occurrence matching v1: literal substring of the primary selection;
  empty selection expands via IdentifierUnderCaret; cap ~1,000.
- v1 limitations stand as the plan states them (IME bail, no per-caret
  auto-indent, current-line highlight suppressed at >1 caret,
  hibernation collapses to primary) — document, don't fix.

Do NOT edit shared doc indexes; record intended rows in the final
report. Stop only when MC1-MC6 are complete and verified, or on a
genuine blocker. Finish with ONE consolidated report: per increment —
changes, files, test delta, deviations, evidence; then spike findings,
the isolated shared-hunk commit id, deferred GUI checklist items, and
the plan's exit status.
```

---

## Prompt 5 — Git depth: hunks, stash, blame (`../rafu-git-depth`)

```
/goal You are the coordinator for the Git-depth lane of Rafu's
post-audit fan-out, running in the dedicated worktree on branch
lane/git-depth. First run `git status --short --branch`; verify the G0
contract commit (GitOpenDiff.scope + WorkspaceSession git-state stubs)
is present in this branch's history — if it is missing, or you are on
the wrong branch, STOP and report.

Read first, in order:
1. AGENTS.md
2. docs/plans/phases/post-audit-worktree-fanout.md
3. docs/plans/phases/git-depth-blame-stash-hunks.md — YOUR CONTRACT:
   increments G1-G4 (G0 is already on main), owned/forbidden paths,
   gates. Repository wins over stale anchors; note deviations, keep
   intent.
4. docs/references/git-process-and-parsing.md,
   docs/decisions/0003-files-left-utility-right.md

Execute increments G1, G2, G3, G4 strictly in order, one advisor →
implementor → verification → documentor cycle each (advisor brief →
your critical review → implementor → independent verification:
swift test --filter Git, then FULL swift test; swift build;
./script/format.sh --fix then --lint → documentor → commit on this
branch → next). Defer build_and_run.sh --verify and the manual passes
(external git status/diff --cached confirmation, keyboard-only,
VoiceOver, second window) to one consolidated pass at G4.

Hard rules:
- Owned/forbidden paths exactly as the plan. WorkspaceSession.swift and
  GitWorkbenchModels.swift were G0-only — do NOT edit them again beyond
  filling the G0 stubs' bodies; GitModels.swift additive types only.
  Editor/** (including CodeEditorView and EditorGutterRulerView — blame
  uses a canvas precisely to avoid them), LanguageIntelligence/,
  Markdown/, RafuCLI/, RafuCore/, Package.* — forbidden/unchanged.
- G4's RafuAppCommands + CommandPaletteView command entries: minimal,
  additive, ONE isolated commit, flagged for the integration owner.
- Invariants: /usr/bin/git + argument arrays only; hunk patches are
  built by slicing rawPatch (NEVER reconstructed from aligned rows — the
  \ No newline marker is lost there); git apply --cached with NO --3way
  and NO --recount; stash refs are always stash@{n} from a validated
  non-negative Int; drop/discarding-pop behind a confirmationDialog; no
  auto-stash anywhere; blame bounded to the focused file, discarded on
  close; no persistent git process; no color-only signalling. New
  @concurrent methods take the swift-concurrency-pro path; the index
  write path takes the AGENTS.md security review.

Decisions pre-resolved for this run:
- G2 stash IS approved (the user requested stash explicitly in the
  fan-out scope); ADR 0011 records that it is off the phase-6 candidate
  list and was user-approved.
- Blame presentation: the read-only editor-hosted canvas, per the plan;
  the gutter alternative is recorded as rejected-for-MVP in ADR 0011.
- If the G1 overlapping-partially-staged round-trip test proves flaky,
  narrow v1 to whole-hunk staging of fully-unstaged files and record it.
- ADR 0011: author with status Proposed; user flips at merge.

Do NOT edit shared doc indexes; record intended rows in the final
report. Stop only when G1-G4 are complete and verified, or on a genuine
blocker. Finish with ONE consolidated report: per increment — changes,
files, test delta, deviations, evidence (including the round-trip
assertions' actual output); then the isolated shared-hunk commit id,
deferred manual checks, and the plan's exit status.
```

---

## Prompt 6 — CLI ↔ app IPC v1 (`../rafu-cli-ipc`)

```
/goal You are the coordinator for the CLI-IPC lane of Rafu's post-audit
fan-out, running in the dedicated worktree on branch lane/cli-ipc.
First run `git status --short --branch`; verify the I0 contract commit
(RafuCore IPC protocol types, WorkspaceSession goto seam signature,
WorkspaceWindowRegistry + WorkspaceSceneRoot hooks, server stub) is
present in this branch's history — if it is missing, or you are on the
wrong branch, STOP and report.

Read first, in order:
1. AGENTS.md
2. docs/plans/phases/post-audit-worktree-fanout.md
3. docs/plans/phases/cli-app-ipc.md — YOUR CONTRACT: the frozen
   protocol section, increments I1-I6 (I0 is already on main),
   owned/forbidden paths, gates. Repository wins over stale anchors;
   note deviations, keep intent.
4. docs/references/launcher-cli.md, docs/references/cli-app-location.md,
   docs/decisions/0007-cli-app-location-symlink.md

Execute increments I1, I2, I3, I4, I5, I6 strictly in order, one
advisor → implementor → verification → documentor cycle each (advisor
brief → your critical review → implementor → independent verification:
swift build; FULL swift test — framing/codec/router/goto/uid suites all
headless over socketpair or in-memory transports; ./script/format.sh
--fix then --lint → documentor → commit on this branch → next). Defer
./script/build_and_run.sh and the nine-item manual end-to-end checklist
to one consolidated pass at I6; run every checklist item you can
non-interactively (cold start, reuse, --new-window, --goto, stale
socket, --wait notice) and list what needs the human.

Hard rules:
- Owned/forbidden paths exactly as the plan. The three I0 files
  (WorkspaceSession.swift beyond filling the goto seam body,
  WorkspaceSceneRoot.swift, ExternalOpenRequests.swift beyond the stub
  bodies) are FROZEN — no further signature or structural changes; if
  the design seems to demand one, stop and report. Package.*,
  RafuApp.swift, LauncherArgumentParser/LauncherInvocation shapes,
  LauncherAppLocator — byte-identical.
- The protocol constants are frozen by the plan: socket at
  ~/Library/Application Support/Rafu/ipc/v1.sock, dir 0700 / socket
  0600, getpeereid check BEFORE any body byte, RAFU magic + wireVersion
  + big-endian length framing, 64 KiB bound, JSON body, typed rejection
  for unknown kind/version.
- Never carry document text or secrets in a payload; log only request
  kind + outcome, never full paths. LauncherIPCServer takes the
  swift-concurrency-pro path (fd ownership, cancellation, Sendable
  buffers); the whole lane takes the AGENTS.md security review;
  window-focus mechanism gets window-management skill review.
- open -a is a starter only (no document argument on the IPC path);
  the document-open fallback is last-resort so `rafu <path>` never
  regresses.

Decisions pre-resolved for this run (all already recorded in the plan /
ADR 0009 skeleton): JSON encoding for local IPC; --wait deferred with
waitSupported:false + one-line CLI notice; goto on a file outside any
workspace opens its containing folder first; WindowAccessor
weak-NSWindow capture for focusing, registry prunes stale refs. Author
ADR 0009 with status Proposed; user flips at merge.

Do NOT edit shared doc indexes; record intended rows in the final
report. Stop only when I1-I6 are complete and verified, or on a genuine
blocker. Finish with ONE consolidated report: per increment — changes,
files, test delta, deviations, evidence; then the manual checklist
items needing the human, security-check results (socket permissions,
log redaction), and the plan's exit status.
```
