# UX-00 — One editor-canvas route, and theme-correct controls

- **Status:** Ready. Branch: `ux/00-canvas-route-and-theme` (from `main`).
  Wave 1 — parallel with UX-03 (fully disjoint). **Blocks UX-01 and UX-02.**
- Deliberately small. Its whole job is to make the next two plans additive
  instead of contended, and to stop the system accent leaking into themed UI.

## Goal

Two mechanical changes with outsized effect:

1. Replace `EditorCanvasView`'s **38-branch `if/else` chain** with one
   explicitly resolved `EditorCanvasRoute`. UX-01 and UX-02 then each add a
   case rather than inserting into a chain in parallel.
2. Adopt the themed control styles that **already exist** at the four sites
   still rendering system blue.

No behaviour changes. Every surface must look and act exactly as it does
today, except that blue controls become theme-accented.

## Read first

`AGENTS.md` (interface rules; "Which test mode, and who runs it");
`docs/references/ui-design-language.md`;
`Sources/RafuApp/Views/EditorCanvasView.swift` (the chain);
`Sources/RafuApp/Support/RafuControlStyles.swift` (`RafuSegmentedPicker`
line 156, `RafuProminentButtonStyle` line 72 — both already written);
`Sources/RafuApp/Models/WorkspaceSession.swift` (the state the chain reads:
`descriptor`, `hasAnyEditorTabs`, `gitOpenBlame`, `gitOpenDiff`,
`conductorRunCanvasID`, `conductorGraphVisible`, `selectedDocumentID`).

## Owned paths

- `Sources/RafuApp/Views/EditorCanvasView.swift` — the route + the branch
- NEW `Sources/RafuApp/Editor/EditorCanvasRoute.swift`
- `Sources/RafuApp/Support/RafuControlStyles.swift` — only if a themed
  segmented style needs a small extension to cover a new call site
- `Sources/RafuApp/Views/ResourcesView.swift`,
  `Views/GitHubPublishSheet.swift`,
  `Views/ConductorRunsPanelView.swift` (lines ~60 and ~696 only),
  `Settings/ThemeSettingsSection.swift` — the leaking control sites
- NEW `Tests/RafuAppTests/EditorCanvasRouteTests.swift`
- NEW `docs/references/editor-canvas-routing.md`; this plan's status line.

**Forbidden:** `Models/WorkspaceSession.swift` (read its state; add nothing
— UX-01/UX-02 own the new seams), everything UX-03 owns
(`WorkspaceTerminalsPanelView`, `TerminalsPanelModel`, `ConductorCLIIcons`,
`FileIconProvider`), `Settings/**` beyond the one `.borderedProminent` site,
and any behaviour change to what a given state renders.

## Design contract

### 1. The route

NEW `Sources/RafuApp/Editor/EditorCanvasRoute.swift`:

```swift
/// What the editor canvas is showing. Resolved in ONE pure function from
/// session state, so adding a canvas mode is a new case plus one branch —
/// not an insertion into a chain whose ordering is load-bearing and
/// undocumented.
nonisolated enum EditorCanvasRoute: Equatable {
    case welcome
    case empty
    case blame
    case standaloneDiff
    case runDetail
    case graph
    case editor
}
```

Plus a pure resolver taking a small `Inputs` value (the booleans/IDs the
chain reads today), so it is testable without a `WorkspaceSession`:

```swift
static func resolve(_ inputs: Inputs) -> EditorCanvasRoute
```

`EditorCanvasView.body` becomes a `switch` over `EditorCanvasRoute.resolve(…)`.

**Preserve the existing precedence exactly.** The current ordering is
load-bearing: welcome → empty → blame → standalone diff → run detail →
graph → editor, with each branch's extra conditions (`selectedDocumentID
== nil` on the diff/detail/graph branches; the emptiness guard's full set)
carried over unchanged. Read the chain and transcribe it; do not
"tidy" the conditions. A behaviour change here is a regression even if it
looks more sensible.

### 2. Theme adoption

Four sites render in the system accent because they use raw AppKit-backed
styles instead of the repo's own:

| Site | Today | Use |
|---|---|---|
| `ResourcesView.swift:169` | `.pickerStyle(.segmented)` | `RafuSegmentedPicker` |
| `GitHubPublishSheet.swift:36` | `.pickerStyle(.segmented)` | `RafuSegmentedPicker` |
| `ConductorRunsPanelView.swift:60` | `.pickerStyle(.segmented)` | `RafuSegmentedPicker` |
| `ConductorRunsPanelView.swift:696` | `.pickerStyle(.segmented)` | `RafuSegmentedPicker` |
| `ThemeSettingsSection.swift:86` | `.buttonStyle(.borderedProminent)` | `RafuProminentButtonStyle` |

Also sweep for any remaining `.borderedProminent`, `.tint(`, or
`accentColor` in `Sources/RafuApp/Views` and `Settings` that is not already
theme-derived, and convert it. If `RafuSegmentedPicker` cannot express a
call site (e.g. it needs a different item shape), extend it — do not fall
back to the system style.

**Verify by eye is not enough**: add a test asserting the themed segmented
control is what these views construct, or — if that is impractical for a
SwiftUI body — a source-scan test asserting `pickerStyle(.segmented)` and
`.borderedProminent` do not appear under `Sources/RafuApp/`. The scan is
the honest guard here, and it is the one that keeps the fix from eroding.

## Tests

- `EditorCanvasRouteTests`: one case per route, plus the precedence pairs
  that matter — blame beats diff, diff beats run detail when
  `selectedDocumentID == nil`, a selected document beats every canvas mode,
  the emptiness guard's exact condition set. Build these from the current
  chain so they encode today's behaviour, not an idealised version.
- Theme guard: source scan for `pickerStyle(.segmented)` /
  `.borderedProminent` under `Sources/RafuApp/` → expect zero.

## Gates

Standard: `./script/build.sh` 0 warnings; `./script/test.sh` (parallel) per
stage; `./script/test.sh --no-parallel` once at the end;
`./script/format.sh --fix` then `--lint`. Delete `.build` as the last step.

**You may run `./script/build_and_run.sh --verify`** — it builds Rafu
Lightning and cannot disturb a release Rafu. Do a visual pass confirming
every canvas mode still renders as before and no control is blue. Never
`pkill`/`pgrep` a bare `Rafu`.

## Documentation deliverables

NEW `docs/references/editor-canvas-routing.md`: the route enum, the
precedence and why each rule exists, how to add a mode (one case + one
branch + one test), and the theme rule — themed styles exist, so a system
accent in Rafu's own chrome is a defect.

## Handoff report

Delivered; changed paths; the transcribed precedence table (before → after,
proving no behaviour change); test evidence; the GUI checks you ran in
Lightning; branch; commit messages; `git rev-parse HEAD`.

---

## Goal-mode agent prompt

```
You are a phase agent for the Rafu repository, working in a dedicated git
worktree. GOAL MODE: you own the outcome end to end; do not ask for
permission between steps; finish or report precisely why you cannot.

Branch: ux/00-canvas-route-and-theme. Preflight: run `git status --short
--branch` ONCE. On this branch + clean tree → proceed. Detached HEAD or
wrong branch + clean tree → checkout it if it exists, else
`git checkout -b ux/00-canvas-route-and-theme main`, then proceed and say
so. Dirty tree with edits you did not make → STOP.

GOAL: implement docs/plans/phases/ux/UX-00-canvas-route-and-theme.md —
replace EditorCanvasView's 38-branch if/else chain with one explicitly
resolved EditorCanvasRoute, and adopt the themed control styles that
already exist at the sites still rendering system blue. Read that plan
FIRST, then AGENTS.md and docs/references/ui-design-language.md.

THIS IS A REFACTOR: no behaviour may change. The chain's ordering is
load-bearing and undocumented — transcribe it exactly, including each
branch's extra conditions, and do NOT tidy a condition because it looks
redundant. Your route tests must encode today's behaviour, not an
idealised version. If you believe a condition is wrong, report it; do not
fix it here.

HARD CONSTRAINTS: do not add anything to WorkspaceSession (UX-01 and UX-02
own the new seams and run right after you); do not touch
WorkspaceTerminalsPanelView, TerminalsPanelModel, ConductorCLIIcons, or
FileIconProvider (UX-03 owns those in parallel); if RafuSegmentedPicker
cannot express a call site, extend it rather than falling back to the
system style. Local builds are Rafu Lightning — you MAY run
./script/build_and_run.sh --verify, but never pkill or pgrep a bare "Rafu",
which is the user's editor.

DEFINITION OF DONE:
1. EditorCanvasView.body is a switch over EditorCanvasRoute.resolve; the
   resolver is pure and tested without a WorkspaceSession.
2. A before/after precedence table in your report proves no behaviour
   change.
3. Zero `pickerStyle(.segmented)` and zero `.borderedProminent` remain
   under Sources/RafuApp/, enforced by a source-scan test.
4. build 0 warnings; parallel suite green per stage; serial suite green
   once at the end; format --fix + --lint clean.
5. editor-canvas-routing.md written; intended index row in the report only.
6. A Lightning GUI pass confirming every canvas mode renders as before and
   no control is blue.
7. Committed in verified stages; `rm -rf .build` as the last step. Never
   push/merge/rebase/checkout main.

FINAL REPORT: delivered; changed paths; the precedence table; test
evidence; GUI checks run; branch; every commit message; last commit id.
```
