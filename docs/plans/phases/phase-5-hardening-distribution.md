# Phase 5 — Hardening and distribution

- **Status:** Planned
- **Depends on:** Phase 4 feature set; continuous earlier-phase tests remain required
- **Canonical scope:** v0.4 §13, §14, §15 Phase 5, and §18

## Goal

Make Rafu reliable, secure, accessible, measurable, signed, and notarized enough for daily use and external direct distribution.

## Scoped deliverables

- Recovery: local/remote crash restoration, incompatible agent rollback, corrupt/noexec upload recovery, watch overflow, disk-full/permission flows, network/sleep/wake, stale SSH/IPC sockets, moved app/CLI.
- Security: documented threat model, CLI/protocol fuzz and negative tests, path traversal/symlink tests, askpass/host-key review, secret scanner fixtures, dependency/build/release-signing process.
- Accessibility/design: VoiceOver, Full Keyboard Access, Reduce Motion/Transparency, Increase Contrast, light/dark/accent behavior, localization readiness, toolbar/compact-window checks.
- Performance: Release regression suite and stored baselines for all §14 fixtures and budgets.
- Distribution: Developer ID signing, hardened runtime/required entitlements, nested launcher/askpass signatures, notarization, signed agent manifest/checksums, privacy policy, reproducible GitHub release artifacts. Direct updater remains deferred until reliability is established.

## Explicit non-goals

- New editor/Git/AI features, general extension host, App Store-specific redesign, or direct updater before core release reliability.
- Cosmetic custom glass work that conflicts with standard controls or measured accessibility/performance.

## Owned paths

- Reliability owner: restoration, watcher, network/process recovery paths and integration tests across existing domains.
- Security owner: `Rafu/Security`, protocol/CLI fuzz fixtures, threat model, agent manifest verification.
- Accessibility/performance owner: `Rafu/DesignSystem`, UI audit fixes, performance fixtures/traces.
- Distribution owner: project signing settings, entitlements, release scripts/manifests, packaging/privacy/release docs.
- Integration owner controls version numbers, bundle metadata, shared build settings, and release candidate assembly.

## Locked decisions

- Developer ID notarized direct download first.
- Preserve user work over automatic recovery convenience.
- Standard system UI and accessibility behavior before custom visual treatment.
- Agent releases carry checksums/build identity; nested helpers are signed.
- Privacy documentation explains SSH agent and AI data flow.

## Open blockers to resolve

- Final bundle identifier, supported macOS deployment range, signing identities, notarization credentials, and release ownership.
- Whether release builds keep always-on theme hot reload.
- Dirty remote-buffer restoration disclosure/storage protection.
- GitHub release artifact format, checksum/signature publication, and update policy.
- Any budget miss from earlier phases; misses require a measured remediation decision, not relabeling.

## Required project references

- [`../../references/project-structure.md`](../../references/project-structure.md)
- [`../../references/build-and-run.md`](../../references/build-and-run.md)
- [`../../references/concurrency.md`](../../references/concurrency.md)
- [`../../references/swiftui-appkit-boundary.md`](../../references/swiftui-appkit-boundary.md)

## Required skills and capabilities

- `.agents/skills/swift-concurrency-pro` for recovery races, cancellation, sleep/wake, and stress review.
- `.agents/skills/swiftui-expert-skill` and `.agents/skills/swiftui-pro` for accessibility, invalidation, and Instruments-driven review.
- `.agents/skills/apple-design` for restraint, feedback, typography, and reduced-motion/transparency behavior.
- `.agents/skills/improve-animations` only as a read-only audit producing bounded plans; it does not implement fixes.
- `build-macos-apps:build-run-debug`, `build-macos-apps:telemetry`, and `build-macos-apps:window-management` for release-candidate behavior; use `build-macos-apps:test-triage` only after a failure.
- `build-macos-apps:signing-entitlements` and `build-macos-apps:packaging-notarization` for exported artifact validation.

## Worktree decomposition and integration order

1. Integration owner freezes the release candidate and publishes exact build/version inputs.
2. Reliability, security, and accessibility/performance worktrees audit in parallel; distribution worktree prepares scripts against unchanged artifacts.
3. Integrate correctness/security fixes first, then accessibility/performance fixes.
4. Rebuild a clean Release candidate; sign nested code and app in the required order.
5. Archive, notarize, staple/validate, assemble checksums/manifests, then run clean-machine smoke tests.
6. Publish only after all evidence and privacy/release docs match the artifact.

## Verification and measurements

- Full §18 test matrix plus disk-full, permission, sleep/wake, network transition, stale sockets, corrupt upload, app move, and crash restoration.
- Fuzz/negative frame and IPC sizes, protocol versions, traversal/symlink boundaries, malformed Git/provider data, and secret scanner fixtures.
- VoiceOver, keyboard-only, contrast, reduced motion/transparency, light/dark, compact windows, multiple displays, and localization expansion.
- Release Instruments fixtures: 50,000 files, 100 tabs, large JSON/diff, IME, rapid external writes, high-latency SSH, disconnect every operation, watch overflow.
- Validate roughly `<150 MB` idle local target, `20–40 MB` remote client increment, `<25 MB` remote agent, one-frame typing p95, zero persistent Git processes, and no preloading.
- Inspect exported app/helpers with `codesign`, `spctl`, entitlements/plists; validate notarization and agent manifest/checksums on a clean machine.

## Exit criteria

- Recovery paths preserve user work and all supported remote targets receive a verified compatible agent.
- Threat model and negative tests cover every documented trust boundary.
- Performance and accessibility gates pass or have an explicitly approved evidence-backed exception.
- Notarized build and signed helpers install/run cleanly; CLI install remains reversible across app movement/update.
- GitHub release artifacts, checksums, privacy notes, and reproducible commands match the tested candidate.

## Documentation handoff

Record the release commit/version, build/archive/notary commands, identities/entitlements without secrets, checksums, supported platforms, test and trace artifacts, threat-model changes, accessibility results, known limitations, rollback procedure, and publication checklist.
