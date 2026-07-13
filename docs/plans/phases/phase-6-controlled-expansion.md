# Phase 6 — Optional controlled expansion

- **Status:** Deferred
- **Depends on:** Phase 5 release and explicit approval for each candidate
- **Canonical scope:** v0.4 §3.3 and §15 Phase 6

## Goal

Consider only bounded additions that preserve Rafu's small-runtime, explicit-trust, native repository-companion identity. Phase 6 is a menu of separately approved goals, not a promise to build every item.

## Candidate deliverables

- Built-in formatter integrations.
- A few opt-in bundled language servers, disabled by default.
- Hunk staging.
- Read-only Git history and blame.
- Open a remote shell in an external Terminal application.
- Remote port-forward management.
- Workspace tasks with explicit trust.

Each candidate requires its own mini-RFC covering user need, process/memory/security cost, local/SSH parity, owned paths, tests, rollback/removal, and effect on the no-extension decision.

## Explicit non-goals

- General extension/plugin marketplace or third-party runtime.
- Embedded terminal, autonomous agent/chat platform, broad LSP ecosystem, debugger, collaboration, remote containers, or silent executable workspace behavior.
- Bundling multiple candidates into one goal merely because they share a phase number.

## Owned paths

- Assign one isolated feature domain/worktree per approved candidate.
- Existing core owners retain `EditorCore`, `Remote`, `Git`, `Security`, and app composition; candidate agents extend only through reviewed interfaces.
- Integration owner alone changes shared protocol versions, trust model, process policy, menus, project files, or performance budgets.
- Experimental code must remain removable without rewriting core editor/workspace models.

## Locked decisions

- No general extension host unless product strategy explicitly changes outside this plan.
- Optional language servers are few, built in, opt-in, and off by default.
- Remote shell opens externally rather than becoming an embedded terminal.
- Executable tasks/formatters/servers require workspace trust and visible process lifecycle.
- Every addition must fit established memory, cancellation, privacy, and local/SSH principles.

## Open blockers to resolve per candidate

- Demonstrated user need after Phase 5 usage.
- Explicit approval and priority relative to maintenance work.
- Measured idle/runtime/process cost and security/threat-model delta.
- Local/remote execution location, trust prompt, cancellation, and failure UX.
- Protocol/version implications and whether the feature can stay surgically removable.

## Required project references

- [`../../references/project-structure.md`](../../references/project-structure.md)
- [`../../references/build-and-run.md`](../../references/build-and-run.md)
- [`../../references/concurrency.md`](../../references/concurrency.md)

## Required skills and capabilities

- Always select `.agents/skills/swift-concurrency-pro` for new process/network actors and cancellation.
- Use `.agents/skills/swiftui-expert-skill` for new UI; optionally add `.agents/skills/swiftui-pro` for a deliberate broad review and `.agents/skills/apple-design` for interaction/trust feedback.
- Use `build-macos-apps:swiftui-patterns`, `build-macos-apps:appkit-interop`, or `build-macos-apps:window-management` only when the approved candidate touches those boundaries.
- Use `build-macos-apps:build-run-debug` and `build-macos-apps:telemetry` for every candidate's proof; use `build-macos-apps:test-triage` only after a failure.
- Re-run `build-macos-apps:signing-entitlements` and `build-macos-apps:packaging-notarization` if a candidate adds binaries, helpers, entitlements, or release contents.

## Worktree decomposition and integration order

1. Write and approve one candidate RFC with baseline measurements and explicit non-goals.
2. Foundation owner adds the smallest typed interface or protocol capability, if needed.
3. Feature implementation and fixtures live in one isolated worktree; a separate reviewer audits security/concurrency/performance.
4. Integrate behind an opt-in or clearly bounded UI, then rerun all prior phase gates.
5. Ship candidates independently; do not wait for or couple unrelated Phase 6 items.

## Verification and measurements

- Candidate-specific correctness, failure, cancellation, trust, local/SSH parity, accessibility, and recovery tests.
- Before/after Release memory, launch, idle process count, typing p95, network/process activity, and package-size measurements.
- Full regression gates for editing, SSH, CLI, Git, AI privacy, signing, and notarization.
- Confirm disabled candidates create no background process/network work and negligible retained state.
- Confirm removal/disable path restores prior behavior without data loss.

## Exit criteria

For each approved candidate:

- Its RFC and threat/performance delta are approved.
- It is independently testable, removable, documented, and does not widen into an extension platform.
- Disabled state has no hidden background runtime.
- Prior phase exit criteria and release validation still pass.
- User-facing value is demonstrated against the measured cost.

Phase 6 itself may remain open indefinitely; completion is per candidate.

## Documentation handoff

Record the approved RFC, ownership, process/trust model, protocol changes, before/after measurements, new commands/settings, disabled-state proof, rollback/removal steps, and release impact. Update this index with a separate status row or child plan for every accepted candidate.
