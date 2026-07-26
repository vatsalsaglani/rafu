# Agent Terminal launch contract

## Applies to

This note applies to the interactive Agent Terminal entry points introduced by
AT-01: the Terminals panel menu, New Agent Terminal sheet, app menu, command
palette, terminal-session identity, and Resources attribution. It does not
apply to Ensemble runs or adapter invocations used by the run engine.

## Last verified

- 2026-07-26
- Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`)
- macOS 26.5.2 (25F84), arm64
- Installed CLI versions are recorded in the probe table below.

## Rule

An Agent Terminal is the user's interactive vendor-CLI session, not an
Ensemble run:

- Spawn an absolute executable with an argument array; never use a shell
  command string.
- Give the child exactly one environment key, `PATH`.
- Start with `RafuConductorEnvironment.curatedPath`. Prepend the parent of the
  adapter-probed executable only when that directory is not already a complete
  PATH component.
- Never add `RAFU_HANDOFF`, `RAFU_RUN_DIR`, `RAFU_ENSEMBLE_TOKEN`, inherited
  credentials, or any other `RAFU_*` key.
- Never attach an output log. The session is interactive user activity, not
  reproducible run evidence.
- Emit a model flag only when the installed CLI's `--help` output verified the
  flag. A hypothesis launches bare and carries a visible verification note.
- Missing and known-unauthenticated CLIs remain visible but disabled with a
  textual reason. An adapter that reports auth as unknown remains launchable
  and lets its own CLI make the authoritative decision.
- The starting directory must resolve to the workspace root or a descendant.
  Resolving symlinks before the containment check prevents a link inside the
  workspace from escaping it.

The launch roster comes from `ConductorAdapterRegistry.all`; a second Agent
Terminal-specific discovery authority would drift from Settings and Ensemble.

## Interactive launch probe table

Each verified row below was checked from the named installed executable using
`--help` on 2026-07-26. “Bare” means no prompt or non-interactive command is
added; the process owns the existing SwiftTerm PTY.

| CLI | Installed version | Interactive argv after the executable | Model argv | Status and evidence |
|---|---:|---|---|---|
| Claude Code (`claude`) | 2.1.220 | `[]` | `["--model", "<model>"]` | **Verified** — help describes interactive use by default and `--model <model>`. |
| Codex (`codex`) | 0.145.0 | `[]` | `["--model", "<model>"]` | **Verified** — no subcommand opens the interactive UI; help lists `-m, --model <MODEL>`. |
| OpenCode (`opencode`) | 1.18.4 | `[]` | `["--model", "<model>"]` | **Verified** — `opencode [project]` starts the TUI in the current directory; help lists `-m, --model`. |
| Cline (`cline`) | 3.0.46 | `["--tui"]` | `["--model", "<model>"]` | **Verified** — help requires `-i, --tui` for the interactive TUI and lists `-m, --model <model-id>`. |
| Kimi CLI (`kimi`) | not installed | `[]` | omitted | **Hypothesis** — bare launch only. Run `kimi --help` after installing it before adding any model flag. |
| Gemini CLI (`gemini`) | 0.52.0 | `[]` | `["--model", "<model>"]` | **Verified** — bare invocation is interactive and help lists `-m, --model`. |
| Cursor CLI (`cursor-agent`) | 2025.09.18-7ae6800 | `[]` | `["--model", "<model>"]` | **Verified** — bare invocation starts the agent and help lists `--model <model>`. |

Probe commands:

```bash
claude --help
codex --help
opencode --help
cline --help
kimi --help
gemini --help
cursor-agent --help
```

The Kimi executable was absent from the adapter's launchd-safe search path as
well as the interactive shell path. Its row is intentionally not inferred from
another product, documentation snippet, or a similarly named binary.

## Identity and lifecycle

`TerminalProcessSpec.agentProvider` carries vendor identity into the existing
terminal controller. The editor tab shows the CLI name; the Terminals panel
and Control-Tab switcher add the provider mark beside that same text.
Resources registers the child as `.agentTerminal`, displayed as **Agent
Terminal**, while Ensemble `.agent` children remain **Ensemble Agent** and
login shells remain **Terminal**.

Agent Terminals use the normal terminal exit, attention, parking, and close
pipeline. Like all terminal editor resources under ADR 0014, they are
ephemeral and never restored after relaunch. No output capture is added:
capturing an interactive conversation would turn user terminal activity into
silent durable evidence and would falsely imply Ensemble run semantics.

## Vendor marks cannot render inside a SwiftUI `Menu` (UX-03)

**Rule: never put a vendored-asset icon in SwiftUI menu content on macOS. Use
`Label(_:systemImage:)` there, and put vendor identity in a normal view.**

SwiftUI bridges `Menu` content to AppKit's `NSMenu`/`NSMenuItem`. An
`NSMenuItem` draws `item.image` at the **image's own size** and honors no
SwiftUI layout modifiers, so `FileIconView`'s `.resizable().frame(width:height:)`
— the thing that makes the mark correct everywhere else — has no effect. Every
vendored `Resources/FileIcons/agent-*.svg` is authored `width="1em"
height="1em"`, which `NSImage` resolves to a **1×1 pt** intrinsic size. The
result was that all seven agent rows in the Terminals panel `+` menu drew as
tiny dots, while the same `FileIconView(icon:size: 18)` in the New Agent
Terminal sheet drew correctly.

This is **not** a catalog or asset defect. The assets are correct per the
normalization rule in [agent icon assets](agent-icon-assets.md) (upstream
`width`/`height` are preserved deliberately), and the catalog resolves the right
file for every `ConductorCLIID`. The container was the defect.

Measured evidence (macOS 26.5.2, Apple Swift 6.3.3, 2026-07-26):

```swift
// Every vendored agent mark:
NSImage(contentsOf: .../agent-codex.svg)!.size        // (1.0, 1.0)

// NSMenuItem does not correct it:
let item = NSMenuItem(title: "Codex", action: nil, keyEquivalent: "")
item.image = NSImage(contentsOf: .../agent-codex.svg)!
item.image!.size                                     // (1.0, 1.0)

// Which is why an SF Symbol survives in the same menu:
item.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)!
item.image!.size                                     // (18.0, 14.0)
```

`FileIconAssetsTests.vendoredAgentMarksHaveOnePointIntrinsicSizeInMenus` pins
all three measurements, so the next attempt to put a mark in a menu fails a test
instead of shipping dots.

A workaround exists — stamping `image.size = NSSize(width: 16, height: 16)`
before handing the `NSImage` to AppKit — and is deliberately **not** used: UX-03
moved agent identity out of the menu entirely, which is also the product
direction (no popups for a primary action).

## Inline agent launcher contract (UX-03)

The Terminals panel's `+` menu now carries shell choices only. Agents launch
from an inline **Agents** section between the panel header and the session list:

- One card per provider from `AgentTerminalLaunchService.options()`, in
  `ConductorAdapterRegistry.all` order. No second discovery authority.
- `AgentLauncherModel.launchableOption(for:in:)` is the only path to a spawn. It
  re-checks the option's availability, so neither a pending card nor a stale
  ready card can reach the launch service.
- Cards are plain buttons, so Full Keyboard Access reaches them by Tab and
  activates by Return/Space. UX-03 mints **no** per-agent global chord: ⌘⇧ is
  already taken by n/f/g/l/k/p/e/a, and ⌘⇧A opens the Agent Terminal sheet.

### The launcher is an icon-only grid (UX2-03)

The original anatomy — full-width rows with mark, name, and a status line, in a
240 pt scroller — read as heavy for what is a seven-item launcher. It is now a
`LazyVGrid` of icon-only cards directly under the panel header:

- `GridItem(.adaptive(minimum: 40, maximum: 60))`, 6 pt gutters, 40 pt-tall
  cards with the vendor mark at 20 pt. The grid reflows with the panel: four
  columns at ~250 pt, all seven on one line at ~400 pt. No `ScrollView` — seven
  cards are at most three short rows, and a scroller would greedily claim
  vertical space the session list needs.
- **No visible name.** That is only legitimate because every card carries the
  name in *both* `.help()` (`AgentLauncherRow.tooltip`) and
  `.accessibilityLabel` (`AgentLauncherRow.accessibilityLabel`). Both strings
  contain the display name in **every** state, and
  `TerminalsPanelTests.agentLauncherTooltipsAlwaysNameTheProvider` asserts it —
  an icon must never be the only carrier of meaning (AGENTS).
- Unavailable providers stay visible and disabled. Their treatment is dimming
  **plus a dashed border** — a shape difference, so it survives grayscale,
  Increase Contrast, and colour-blind vision — and the
  `AgentTerminalAvailability.reason` rides in the tooltip and the accessibility
  label. Dimming is never the sole signal, and nothing is silently hidden: the
  header still reads "*n* of 7 ready".
- Hover raises the card to `palette.hover` over 120 ms. Theme tokens only; no
  system accent.

### The probe needs a visible pending state, not an empty list

`options()` spawns one real CLI per provider to resolve installation and auth,
which is visibly slow on a cold run. Rendering an empty list during that window
reads as "no agents installed" — a lie while the answer is unknown. So:

- The panel holds `[AgentTerminalOption]?`; `nil` means *probing*, `[]` means
  *resolved and empty*. These must never look the same.
- While probing, `AgentLauncherModel.probingRows()` renders every known provider
  as a disabled, dashed card whose tooltip reads
  "*Name* — checking whether it is installed…", and the header reads
  `Agents (checking…)` with a spinner — the ready count is withheld until it is
  true. The grid is never empty and never fills in silently.
- The probe runs once per `.task(id:)` identity (workspace root + an explicit
  refresh token), never per render. The section's refresh control bumps that
  token; it is the only way to re-probe.

## The file-tree and agent icon catalogs stay separate (decision)

The Codex mark differs between the file tree and agent surfaces. That is
**intended**, and UX-03 keeps it:

- `Resources/FileIcons/codex.svg`, `claude.svg`, `gemini.svg` decorate
  **directories and files** (`.codex/`, `CLAUDE.md`, …) via
  `FileIconProvider`'s tables. They predate AT-01, come from a different source,
  and are byte-pinned by `FileIconAssetsTests`.
- `Resources/FileIcons/agent-*.svg` identify **providers** via
  `ConductorCLIIcons`, and come as a uniform seven-mark set from the pinned
  lobe catalog.

Pointing agent surfaces at the file-tree asset would couple provider identity to
file-name decoration and break the uniformity of the seven-mark set; pointing the
file tree at the agent assets would rewrite byte-pinned decoration for no
product gain.

One asset did need correcting: dogfooding showed the lobe `codex` mark was not
recognisable as Codex, which matters more now that the launcher is icon-only.
UX2-03 refreshed `agent-codex.svg` from the same pinned 1.94.0 catalog using the
`openai` slug — the fix went through the documented refresh path, *not* by
pointing the agent catalog at the file tree's `codex.svg`. Do the same for any
future mark; see [agent icon assets](agent-icon-assets.md).

## Why it matters

The one-action launch is useful only if it does not quietly become an
authorization boundary. Exact environment and verified-argv rules keep the
session equivalent to the vendor CLI the user chose to run, while distinct
identity prevents Resources and navigation surfaces from claiming it is an
Ensemble agent.

## Reproduction and verification

```bash
swift test --filter AgentTerminal
swift test --filter 'TerminalsPanel|EditorTabSwitcher|ProcessAttribution'
swift test --filter FileIconAssets
swift test --no-parallel
```

`TerminalsPanelTests`' UX-03 group proves the pending-state roster, the reason
text on unavailable rows, the accessibility labels, the launch gate, and that a
ready row opens exactly one provider-carrying session.
`FileIconAssetsTests` pins the NSMenu measurements above.

The focused tests prove the gating matrix, PATH-only environment, absence of
Ensemble keys and output capture, adapter-directory prepend rule, verified-only
model flags, workspace containment, session reveal, provider identity, and
resource labels.

## Related

- [ADR 0004](../decisions/0004-embedded-terminal.md)
- [ADR 0014](../decisions/0014-terminal-as-editor-tab.md)
- [ADR 0018](../decisions/0018-conductor-external-agent-orchestration.md)
- [ADR 0021](../decisions/0021-agent-terminals.md)
- [AT-01 phase](../plans/phases/conductor/AT-01-agent-terminal-sessions.md)
- [UX-03 phase](../plans/phases/ux/UX-03-agent-identity-and-terminals.md)
- [PTY spawn and child environment](conductor-pty-spawn-and-child-environment.md)
- [Agent icon assets](agent-icon-assets.md)
