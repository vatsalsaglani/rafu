# Rafu agent guide

## Mission and current checkpoint

Rafu is a small, native macOS repository companion for focused edits beside terminal-based coding agents. It is not a general IDE. Protect the product's defining constraints: native interaction, predictable memory, explicit user control, and a deliberately narrow feature set.

The repository is currently at the **pre-initial-push workbench checkpoint**. The active acceptance contract is [`docs/plans/phases/pre-initial-push-workbench.md`](docs/plans/phases/pre-initial-push-workbench.md). It intentionally pulls polished local editing, search, Markdown, Git, themes, provider-backed commit drafting, restoration, and workbench navigation forward before the user creates the first commit in Rafu. SSH and distribution remain later phases.

Explicit initial-product non-goals include an extension host, embedded coding agent, debugger, collaboration, full LSP ecosystem, custom SSH stack, and per-document web views. The embedded terminal was originally a non-goal; the user reversed that in ADR 0004 — one lazy, bounded SwiftTerm panel per window, no task runners or automatic command execution.

## Sources of truth

Apply guidance in this order:

1. The user's explicit current direction. When it intentionally changes a durable decision, update or supersede the affected ADR in the same work.
2. Accepted decisions in [`docs/decisions/`](docs/decisions/).
3. The active phase/worktree plan for execution scope, ownership, order, and gates.
4. [`docs/plans/rafu_product_architecture_plan.md`](docs/plans/rafu_product_architecture_plan.md), the canonical product plan.
5. Verified engineering notes indexed by [`docs/references/README.md`](docs/references/README.md).
6. Skill and plugin guidance.

[`docs/plans/rafu_plan.html`](docs/plans/rafu_plan.html) is a visual rendering of the canonical Markdown plan, not a second specification. Plan v0.4 supersedes stale v0.3 naming in the raw theme artifacts: use **Rafu**, **Indigo**, and **Khadi**, not Darn or Linen.

An active phase brief cannot silently supersede an ADR. When non-user sources disagree, follow the accepted decision or record the unresolved choice and add a superseding ADR before making a durable commitment.

## Start every implementation task here

1. Read this file, the active phase document in [`docs/plans/phases/`](docs/plans/phases/), and every reference it marks as required.
2. Inspect `git status --short --branch` and preserve unrelated user changes.
3. Confirm the task's owned paths and phase boundary before editing.
4. Select skills using [`docs/references/skill-routing.md`](docs/references/skill-routing.md). Skill examples never override Rafu's macOS architecture.
5. Decide what evidence will prove the change: build, tests, launch behavior, logs, trace, memory measurement, or an explicit manual check.

## Canonical commands

- Build everything: `swift build`
- Run all tests: `swift test`
- Exercise the CLI: `swift run rafu --help`
- Build and launch the GUI app bundle: `./script/build_and_run.sh`
- Build, launch, and verify the GUI process: `./script/build_and_run.sh --verify`

The Codex Run action lives in [`.codex/environments/environment.toml`](.codex/environments/environment.toml) and must call the same build-and-run script. Do not launch the SwiftUI product as a raw SwiftPM executable for normal GUI verification; stage and open a real `.app` bundle.

See [`docs/references/build-and-run.md`](docs/references/build-and-run.md) for the supported modes and troubleshooting contract.

## Architecture invariants

- Use SwiftUI for scenes, window composition, toolbars, commands, settings, sheets, and observable UI metadata.
- Use a narrow AppKit/TextKit 2 boundary for the editor and responder-chain behavior SwiftUI cannot provide cleanly.
- Use `WindowGroup` for independent workspace windows. Each window owns exactly one `WorkspaceSession` and its ephemeral selection/layout state.
- Never place a document's live full text in SwiftUI observable state. `NSTextStorage`/`NSTextView` own live text; observation exposes only small metadata such as identity, revision, dirty state, selection metadata, and connection state.
- Keep UI-visible coordination on `@MainActor`. File I/O, syntax parsing, SSH, Git, AI, and other blocking or CPU-heavy work must be isolated away from the main actor, cancellable where relevant, and reviewed for `Sendable` correctness.
- Local and SSH workspaces share domain models and a `WorkspaceFileSystem` boundary. Views must not become parallel local/remote implementations.
- A remote path is not a local `file://` URL. Preserve workspace identity and remote path semantics explicitly.
- Use system `/usr/bin/ssh`; never build a second SSH configuration or authentication authority.
- Spawn processes with an executable plus argument array. Never interpolate workspace, Git, SSH, or user input into a shell command string.
- Keep Git and AI explicit. No automatic commit, no automatic diff transmission, and no silent overwrite of external changes.
- Store secrets in Keychain, never `UserDefaults`, source files, fixtures, or logs. Never log document text, diffs, credentials, askpass responses, or API request bodies.
- Keep Markdown preview native and shared through the approved MarkdownUI boundary. Do not add one `WKWebView` per document.
- Do not introduce an extension/plugin runtime or long-lived language servers without an explicit product-strategy ADR.

## Swift and module rules

- Use Swift 6.2 language mode with strict concurrency checking.
- The GUI target uses default `MainActor` isolation because it is UI/lifecycle-heavy. Shared domain and CLI targets remain nonisolated by default; actor boundaries there must be explicit.
- Prefer value types that honestly conform to `Sendable`. Do not use `@unchecked Sendable` as a compiler escape hatch.
- Prefer `@Observable` plus private `@State` ownership for new UI reference state. Pass injected observable models explicitly; use `@Bindable` only when a child needs bindings.
- Keep `@State` and `@FocusState` private. Do not mark parent-provided values as `@State`.
- Keep business logic, process execution, networking, and filesystem access out of SwiftUI view bodies.
- Keep views small and responsibility-focused. Extract real `View` types for independent sections rather than growing one `ContentView` or using large computed subviews.
- Use stable identity in lists and file trees. Do not sort, parse, format paths, generate icons, or perform other expensive work in `body`.
- Prefer Foundation and Apple frameworks until a phase plan explicitly approves a dependency. Evaluate editor, Tree-sitter, Markdown, and remote-protocol dependencies behind replaceable boundaries before adoption.

## macOS interface rules

- Design for pointer, keyboard, menus, accessibility, and multiple windows from the first implementation.
- Use standard scenes and controls before custom chrome: `WindowGroup`, `Settings`, commands, toolbars, `NavigationSplitView`, inspectors, native lists, sheets, and alerts.
- Follow ADR 0002: one visually quiet Files/Search/Source Control Navigator selected by an icon-only activity strip, one system sidebar toggle, and editor-hosted diffs/details. Do not reintroduce a permanent Git inspector or compressed principal-toolbar file icon.
- Keep the editor canvas opaque and calm. Reserve color for meaning, and never communicate Git or connection state using color alone.
- Use system-adaptive chrome. Indigo/Khadi tokens may style editor/content surfaces, but do not paint native sidebars with opaque custom backgrounds or recreate Liquid Glass.
- Important actions need a visible UI path and a menu/keyboard path. Do not hide core actions behind gestures or icon-only context menus.
- Respect VoiceOver, Full Keyboard Access, Reduce Motion, Reduce Transparency, Increase Contrast, and user text settings.
- Frequent keyboard actions and tab/cursor changes are immediate; do not add decorative motion to them.

## Performance and security evidence

Native implementation is an opportunity, not proof, of lower resource use. Preserve these plan budgets and measure in Release builds when the relevant phase begins:

- Idle local workspace resident-memory target: roughly below 150 MB.
- Syntax parsing only for open buffers; file trees load lazily.
- No persistent local Git process and no complete repository preload.
- Typing-path work targets one display frame at p95.
- Remote and AI work never blocks typing.

Any change to process execution, IPC, remote paths, file writes, credentials, Git hooks, diff transmission, signing, or restoration needs a security review appropriate to its phase. Prefer bounded messages, atomic writes, expected-version checks, private sockets, redacted logging, and explicit trust transitions.

## Tests and verification

- Add focused tests with new domain behavior and regression tests with every bug fix.
- Prefer Swift Testing for new tests. Await async APIs directly; do not use fixed sleeps as synchronization.
- Run `swift test` before handoff. Run the canonical app script when app sources, resources, scenes, packaging, or launch behavior change.
- UI changes require at least a launch/usability pass covering a second window, keyboard reachability, and selection/state ownership where applicable.
- Concurrency changes require the `swift-concurrency-pro` review path. Performance claims require Instruments/signpost evidence, not intuition.
- Treat warnings as work to resolve or document; do not suppress them broadly.

## Standing learning and documentation rule

**A task is not complete if implementation reveals a reusable platform, SDK, toolchain, lifecycle, concurrency, security, performance, packaging, or testing nuance and that nuance is not documented in the same change.**

Classify what was learned:

- Use an ADR in [`docs/decisions/`](docs/decisions/) for a choice among viable alternatives that changes architecture, compatibility, data flow, or a long-term constraint.
- Use a focused note in [`docs/references/`](docs/references/) for verified behavior, ownership rules, commands, failure modes, SDK quirks, measurements, and repeatable diagnostics.
- Update the active phase plan when scope, dependency order, owned paths, or exit criteria changes.

Every reference note must state what it applies to, the last verified toolchain/OS, the rule or observation, why it matters, reproduction/evidence, verification commands, and related code/ADR/phase. Add it to [`docs/references/README.md`](docs/references/README.md). Promote a note into this file only when nearly every future task must know it.

During final review, explicitly check for newly learned nuances. If there were none, no documentation-only churn is required.

## Skill and plugin routing

Use the exact routing table in [`docs/references/skill-routing.md`](docs/references/skill-routing.md). Key defaults:

- Use the project-local `swiftui-expert-skill` while implementing or reviewing SwiftUI; read its latest-API reference first and use its macOS routes.
- Use the project-local `swift-concurrency-pro` for actors, tasks, async streams, continuations, cancellation, process I/O, or cross-actor state. Use only the root skill file, not its nested duplicate.
- Use Build macOS Apps `swiftui-patterns` for scenes, commands, settings, toolbars, split layouts, and inspectors.
- Use Build macOS Apps `build-run-debug` for the canonical run script and any build, launch, startup, or runtime diagnosis.
- Use Build macOS Apps `appkit-interop` when the work crosses into `NSTextView`, TextKit, responder chains, panels, or lower-level window behavior.
- Use Build macOS Apps packaging/signing capabilities only when the active hardening/distribution scope calls for them.

## Phase and worktree contract

- The bootstrap repository needs an initial commit before Git worktrees can be created. Do not attempt phase worktree fan-out before that commit exists.
- One worktree/agent owns one bounded phase workstream and the paths named by its phase document.
- Avoid concurrent ownership of `Package.swift`, `AGENTS.md`, shared indexes, protocol contracts, and project/build metadata. Land shared contracts first, then fan out.
- A worktree handoff includes: delivered behavior, changed paths, verification evidence, remaining risks, references/ADRs updated, and the next integration dependency.
- Do not commit, push, open a pull request, publish a release, or choose a license unless the user explicitly asks for that external/repository action.

## Definition of done

A change is complete only when it:

1. Fits the active phase and preserves the architecture invariants.
2. Builds and passes the relevant focused and full tests.
3. Uses the canonical app launch verification when GUI behavior changed.
4. Includes accessibility, concurrency, security, and performance checks proportional to the risk.
5. Updates ADRs, references, and/or the phase plan for every durable decision or newly discovered nuance.
6. Leaves no secrets, generated build products, unrelated edits, or knowingly stale guidance in the diff.
