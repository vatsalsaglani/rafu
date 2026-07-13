# Planning index

## Canonical product plan

[`rafu_product_architecture_plan.md`](rafu_product_architecture_plan.md) v0.4 is the source of truth for Rafu's product intent, architecture, scope, phases, budgets, security posture, and decision register.

[`rafu_plan.html`](rafu_plan.html) is its styled Indigo/Khadi presentation. Treat it as a rendered companion rather than an independent specification.

## Goal mode and worktrees

[`phases/README.md`](phases/README.md) turns the canonical delivery sequence into worktree-ready briefs. Start one goal from one brief:

- [Active pre-initial-push workbench](phases/pre-initial-push-workbench.md)
- [Phase 0 — feasibility and architecture locks](phases/phase-0-feasibility.md)
- [Phase 1A — local workspace and internal v0.1](phases/phase-1a-local-workspace.md)
- [Phase 1B — SSH workspace parity](phases/phase-1b-ssh-workspace.md)
- [Phase 1C — CLI and desktop integration](phases/phase-1c-cli-integration.md)
- [Phase 2 — editing completeness and performance](phases/phase-2-editor-completeness.md)
- [Phase 3 — local and remote Git](phases/phase-3-git.md)
- [Phase 4 — AI-generated commit messages](phases/phase-4-ai-commit-messages.md)
- [Phase 5 — hardening and distribution](phases/phase-5-hardening-distribution.md)
- [Phase 6 — controlled optional expansion](phases/phase-6-controlled-expansion.md)

The active vertical slice is described in the phase index and is not Product Phase 0. Its hands-on gate and Rafu-created initial Git commit are required before agents can create independent Git worktrees.

## Visual and palette artifacts

- [`rafu-icon-seam.svg`](rafu-icon-seam.svg) is the source concept for the seam icon.
- `darn-theme-indigo.json` and `darn-theme-linen.json` are historical v0.3 inputs whose color values informed v0.4. Their Darn/Linen names, schema URL, IDs, and descriptions are stale.
- Canonical runtime copies are [`../../Resources/Themes/indigo.json`](../../Resources/Themes/indigo.json) and [`../../Resources/Themes/khadi.json`](../../Resources/Themes/khadi.json), with Rafu v0.4 naming.

Do not silently copy historical theme metadata into the app. Phase 1A must lock the final version-1 schema before user-theme compatibility is promised.
