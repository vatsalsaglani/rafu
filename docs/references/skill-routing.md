# Skill and plugin routing

- **Applies to:** selecting project-local skills and Build macOS Apps capabilities
- **Last verified:** complete local skill catalog and Build macOS Apps 0.1.4 on 2026-07-12

This is an operational registry rather than an SDK-behavior note. Its evidence is the linked `SKILL.md` sources and the phase matrix below; re-audit it whenever skills/plugins are added, removed, or upgraded.

This is the operational routing reference for Rafu agents. Read it from the
root [`AGENTS.md`](../../AGENTS.md) before selecting a skill. It explains when
each project-local skill and each Build macOS Apps capability applies; it does
not expand product scope.

## Precedence

Apply guidance in this order:

1. The user's explicit current direction; update or supersede a durable decision when that direction intentionally changes it.
2. Accepted decisions in `docs/decisions/`.
3. The active phase/worktree plan for execution scope, ownership, order, and gates.
4. The canonical product plan,
   `docs/plans/rafu_product_architecture_plan.md`.
5. Verified notes in `docs/references/`.
6. Skill and plugin instructions.

Within the skill layer:

- Prefer the narrowest relevant skill over a broad review skill.
- Prefer a macOS-specific Build macOS Apps capability over web or iOS examples
  for platform implementation.
- Use project-local skills for their specialist judgment, but translate their
  examples through Rafu's architecture and deployment target.
- Combine skills only when they have distinct jobs. For example,
  `swiftui-patterns` may shape a scene while `swift-concurrency-pro` reviews the
  asynchronous service it uses.
- Skill examples do not authorize a dependency, feature, deployment-target
  change, AppKit rewrite, custom visual system, or architecture change.
- If applicable guidance conflicts with an accepted decision, follow the
  decision and document the conflict instead of silently blending them.

## Duplicate project-local skills

Two imported skills contain nested plugin copies that are also discovered as
skills. Do not invoke or link the nested copies:

- Use `.agents/skills/swift-concurrency-pro/SKILL.md`; ignore
  `.agents/skills/swift-concurrency-pro/skills/swift-concurrency-pro/SKILL.md`.
- Use `.agents/skills/swiftui-pro/SKILL.md`; ignore
  `.agents/skills/swiftui-pro/skills/swiftui-pro/SKILL.md`.

The root copies are canonical for this repository. The nested copies are older
or assume a different reference-directory layout, so selecting both can yield
duplicate or contradictory advice.

## Project-local skills

### `animation-vocabulary`

Source: [`.agents/skills/animation-vocabulary/SKILL.md`](../../.agents/skills/animation-vocabulary/SKILL.md)

Use only when someone describes a motion effect without knowing its name. Lead
with the glossary term and disambiguate close matches. Do not use this skill to
design, audit, or implement motion.

### `apple-design`

Source: [`.agents/skills/apple-design/SKILL.md`](../../.agents/skills/apple-design/SKILL.md)

Use for interaction principles such as immediate feedback, spatial continuity,
interruptibility, restraint, reduced motion, typography, and physical gesture
behavior. Its implementation examples target the web; never copy CSS,
JavaScript, pointer-event, or browser-material techniques into Rafu. Translate
the principle into native SwiftUI/AppKit and pair it with a macOS plugin skill
when implementation is requested.

### `design-an-interface`

Source: [`.agents/skills/design-an-interface/SKILL.md`](../../.agents/skills/design-an-interface/SKILL.md)

Use before locking an important protocol or module interface when requirements
are known but multiple shapes remain viable. Generate at least three genuinely
different designs in parallel, compare depth and misuse resistance, and then
synthesize. This skill is design-only: do not implement while running its
workflow. It is especially useful for `WorkspaceFileSystem`, editor command,
remote protocol, Git client, AI-provider, and launcher IPC boundaries.

### `improve-animations`

Source: [`.agents/skills/improve-animations/SKILL.md`](../../.agents/skills/improve-animations/SKILL.md)

Use only after a meaningful motion surface exists and the request is for a
motion audit or implementation roadmap. It is read-only on source: no builds,
formatters, source edits, or fixes. Because Rafu's product plans already occupy
`docs/plans/`, write any output to root `animation-plans/`. Do not use this
skill for an ordinary animation implementation or a review of one small diff.

### `swift-charts`

Source: [`.agents/skills/swift-charts/SKILL.md`](../../.agents/skills/swift-charts/SKILL.md)

Use only when Rafu deliberately adds a real Swift Charts visualization or when
reviewing existing Swift Charts code. No current phase requires charts. Do not
introduce dashboard charts merely because this skill is present.

### `swift-concurrency-pro`

Source: [`.agents/skills/swift-concurrency-pro/SKILL.md`](../../.agents/skills/swift-concurrency-pro/SKILL.md)

Use whenever writing or reviewing actors, tasks, async streams, continuations,
cancellation, process stdout/stderr draining, cross-actor state, or async file,
SSH, Git, AI, and IPC code. It is a required review path for concurrency
changes. Load only the references relevant to the change, preserve Swift 6.2
strict-concurrency checking, prefer structured cancellation, and never use
`@unchecked Sendable` as a diagnostic escape hatch.

### `swiftdata-pro`

Source: [`.agents/skills/swiftdata-pro/SKILL.md`](../../.agents/skills/swiftdata-pro/SKILL.md)

Do not use under the current architecture: Rafu currently chooses explicit
stores, `UserDefaults`/`@AppStorage` for nonsecret preferences, and Keychain for
secrets. Use this skill only after an accepted ADR deliberately adopts
SwiftData for a defined persistence boundary.

### `swiftui-expert-skill`

Source: [`.agents/skills/swiftui-expert-skill/SKILL.md`](../../.agents/skills/swiftui-expert-skill/SKILL.md)

This is the preferred project-local skill for implementing or reviewing
SwiftUI state, view composition, invalidation/performance, lists, focus,
accessibility, navigation, localization, previews, and macOS scenes/views.
Read its `references/latest-apis.md` first whenever invoked, then load only the
topic references that apply. Use its macOS routes and Rafu's macOS availability
requirements; iOS examples and iOS 26 assumptions are not project decisions.

### `swiftui-liquid-glass`

Source: [`.agents/skills/swiftui-liquid-glass/SKILL.md`](../../.agents/skills/swiftui-liquid-glass/SKILL.md)

Do not use this iOS 26-specific skill for Rafu's macOS UI. For an explicitly
approved macOS Liquid Glass task, use Build macOS Apps `liquid-glass` instead.

### `swiftui-pro`

Source: [`.agents/skills/swiftui-pro/SKILL.md`](../../.agents/skills/swiftui-pro/SKILL.md)

Use only for a dedicated, broad second-pass SwiftUI review when that extra pass
is useful. Do not automatically invoke it alongside `swiftui-expert-skill`, and
do not inherit its iOS 26 default deployment assumption. The project plan,
macOS target, and the root copy of this skill remain authoritative.

## Build macOS Apps capabilities

Use the capability names below through the Build macOS Apps plugin. Read the
selected capability's complete `SKILL.md` and its routed references before
acting.

### `build-macos-apps:swiftui-patterns`

Use for new macOS scaffolding and for scene, command, toolbar, Settings,
sidebar-detail, split-view, and inspector architecture. It is the primary
macOS UI-structure capability. The feature-oriented source layout in Rafu's
plan overrides its generic folder examples. Use `appkit-interop` rather than
forcing a SwiftUI workaround when a real platform capability is missing.

### `build-macos-apps:build-run-debug`

Use to create or maintain the one canonical `script/build_and_run.sh`, wire
`.codex/environments/environment.toml`, build or launch the app, and diagnose
compiler, linker, startup, runtime, or logging failures. Normal GUI verification
must launch a staged `.app` bundle, never a raw SwiftPM GUI executable. Keep the
script's `--debug`, `--logs`, `--telemetry`, and `--verify` modes coherent.

### `build-macos-apps:appkit-interop`

Use when crossing into `NSTextView`/TextKit 2, `NSOutlineView`, `NSWindow`,
panels, drag/drop or pasteboard edges, responder-chain behavior, menu
validation, or first-responder control. Name the SwiftUI capability gap and use
the smallest bridge that closes it. SwiftUI owns value state; coordinators and
AppKit objects must not become a second app architecture.

### `build-macos-apps:window-management`

Use for window role, chrome, title and toolbar visibility, drag regions,
placement, sizing, restoration, launch behavior, or borderless/specialized
windows. Prefer SwiftUI scene/window modifiers before reaching for `NSWindow`,
then verify the result through the foreground `.app` launch path.

### `build-macos-apps:view-refactor`

Use when a macOS view or scene mixes unrelated responsibilities, owns too much
state, spreads AppKit through the tree, or needs stable subview and file
boundaries. Preserve behavior unless the active task explicitly includes a
behavioral change. Do not invoke it for every small SwiftUI edit.

### `build-macos-apps:liquid-glass`

Use only for an explicitly scoped macOS Liquid Glass implementation or review.
Follow decision D-012: adopt standard system scenes, toolbars, sidebars, sheets,
and controls first; remove conflicting custom chrome before adding custom glass.
Gate newer APIs and provide a fallback for Rafu's eventual deployment target.
Do not use it as a reason to decorate the editor canvas or file rows.

### `build-macos-apps:swiftpm-macos`

Use when `Package.swift` is the build entrypoint, including Rafu's package-first
bootstrap, library targets, tests, and true CLI products. Use `swift build` and
`swift test`, with filters when useful. `swift run rafu` is valid for the CLI;
the GUI app still follows `build-run-debug` and launches as an app bundle.

### `build-macos-apps:telemetry`

Use to add or verify narrowly scoped `Logger` events and signposts for windows,
commands, file operations, SSH state, Git/AI milestones, and measured spans.
Use stable subsystem/category names and verify emitted events. Never log source
text, diffs, paths that reveal sensitive data, credentials, prompts, tokens, or
API bodies; remove noisy temporary instrumentation before handoff.

### `build-macos-apps:test-triage`

Use after a test failure to find the smallest failing scope and classify it as
a build, assertion, crash, async timing, environment, fixture, entitlement, or
host-app issue. It is a diagnosis workflow, not a substitute for writing and
running ordinary tests.

### `build-macos-apps:signing-entitlements`

Use for an actual code-signing, sandbox, entitlement, hardened-runtime,
Gatekeeper, or trust failure, or when Phase 5 explicitly validates those areas.
Inspect the real artifact and distinguish local development signing from
distribution requirements. Never invent an entitlement to silence a symptom.

### `build-macos-apps:packaging-notarization`

Use when work is explicitly about archives, exported app bundles, Developer ID
distribution, hardened-runtime readiness, notarization, or a distribution-only
failure. This normally belongs to Phase 5 and is not required for local debug
runs.

## Phase quick matrix

The active phase document remains authoritative. This matrix is a fast starting
point, not permission to pull later-phase features forward.

| Phase/workstream | Primary routes | Conditional routes |
|---|---|---|
| Bootstrap | `swiftui-expert-skill`; `build-macos-apps:swiftui-patterns`; `build-macos-apps:swiftpm-macos`; `build-macos-apps:build-run-debug` | `swift-concurrency-pro` for async code; `build-macos-apps:appkit-interop` only for an actual editor bridge; `build-macos-apps:test-triage` only on failure |
| Phase 0A — editor feasibility | `swiftui-expert-skill`; `swift-concurrency-pro`; `build-macos-apps:appkit-interop`; `build-macos-apps:build-run-debug`; `build-macos-apps:telemetry` | `design-an-interface` before locking editor/buffer commands; `apple-design` for interaction principles |
| Phase 0B — SSH transport | `swift-concurrency-pro`; `design-an-interface`; `build-macos-apps:telemetry`; `build-macos-apps:build-run-debug` | `swiftui-expert-skill` and `build-macos-apps:swiftui-patterns` for askpass/trust UI; `build-macos-apps:test-triage` on failure |
| Phase 0C — CLI/IPC | `swift-concurrency-pro`; `design-an-interface`; `build-macos-apps:swiftpm-macos`; `build-macos-apps:build-run-debug`; `build-macos-apps:telemetry` | `build-macos-apps:test-triage` on failure |
| Phase 1A — local workspace | `swiftui-expert-skill`; `swift-concurrency-pro`; `build-macos-apps:swiftui-patterns`; `build-macos-apps:appkit-interop`; `build-macos-apps:window-management`; `build-macos-apps:telemetry`; `build-macos-apps:build-run-debug` | `apple-design` for interaction review; `build-macos-apps:liquid-glass` only for explicit, gated system-chrome work; `build-macos-apps:view-refactor` as structure grows |
| Phase 1B — SSH parity | `swift-concurrency-pro`; `design-an-interface`; `swiftui-expert-skill`; `build-macos-apps:swiftui-patterns`; `build-macos-apps:telemetry`; `build-macos-apps:build-run-debug` | `build-macos-apps:window-management` for window-scoped auth/reconnect presentation; `build-macos-apps:test-triage` on failure |
| Phase 1C — CLI integration | `swift-concurrency-pro`; `build-macos-apps:swiftpm-macos`; `build-macos-apps:build-run-debug`; `build-macos-apps:telemetry` | `design-an-interface` for routing/`--wait` protocol changes; `build-macos-apps:signing-entitlements` only for a concrete installation/signing issue |
| Phase 2 — editor completeness/performance | `swiftui-expert-skill`; `swift-concurrency-pro`; `build-macos-apps:appkit-interop`; `build-macos-apps:view-refactor`; `build-macos-apps:telemetry`; `build-macos-apps:build-run-debug` | `apple-design` for gestures/motion; `improve-animations` for a requested read-only audit; `animation-vocabulary` only to name an effect |
| Phase 3 — Git | `swift-concurrency-pro`; `design-an-interface`; `swiftui-expert-skill`; `build-macos-apps:swiftui-patterns`; `build-macos-apps:telemetry`; `build-macos-apps:build-run-debug` | `build-macos-apps:test-triage` for parser/process regressions |
| Phase 4 — AI commit messages | `swift-concurrency-pro`; `design-an-interface`; `swiftui-expert-skill`; `build-macos-apps:telemetry`; `build-macos-apps:build-run-debug` | `build-macos-apps:test-triage` for provider/network regressions |
| Phase 5 — hardening/distribution | `swiftui-expert-skill`; `build-macos-apps:build-run-debug`; `build-macos-apps:telemetry`; `build-macos-apps:signing-entitlements`; `build-macos-apps:packaging-notarization` | `build-macos-apps:test-triage` only after a failure; `improve-animations` for an explicit accessibility/motion audit; `build-macos-apps:window-management` and `build-macos-apps:liquid-glass` for final platform review |
| Phase 6 — controlled expansion | Select the narrowest route for the approved feature | `swift-charts` or `swiftdata-pro` only after scope and architecture explicitly require them |

## Current bootstrap selection

At the current pre-Phase-0 bootstrap checkpoint, use only what is needed to
establish the package, app and CLI shells, native scene structure, canonical
commands, documentation, and verification:

1. **Required:** `build-macos-apps:swiftui-patterns` for the native multi-window
   shell and scene ownership.
2. **Required:** `build-macos-apps:swiftpm-macos` for the package-first app, CLI,
   and tests.
3. **Required:** `build-macos-apps:build-run-debug` for the app-bundle run script
   and Codex Run action.
4. **Required for SwiftUI changes:** `swiftui-expert-skill`, using its macOS
   references and latest-API check.
5. **Conditional:** `swift-concurrency-pro` only if bootstrap code introduces
   tasks, actors, streams, process I/O, or cross-actor state.
6. **Conditional:** `build-macos-apps:appkit-interop` only if bootstrap includes
   a real TextKit/AppKit bridge rather than a documented placeholder.
7. **Conditional:** `build-macos-apps:test-triage` only when a build or test is
   failing and needs diagnosis.

Do not use Liquid Glass, animation-audit, charts, SwiftData, SSH, Git, AI,
signing, packaging, or notarization skills during bootstrap unless the user
explicitly changes the checkpoint. Return to [`AGENTS.md`](../../AGENTS.md) for
the architecture invariants, commands, phase boundaries, and definition of
done.
