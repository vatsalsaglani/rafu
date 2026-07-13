# Phase 3 — Git for local and SSH workspaces

- **Status:** Planned
- **Depends on:** Phase 2
- **Canonical scope:** v0.4 §11, §13 Git controls, and §15 Phase 3

## Goal

Complete the edit-review-stage-commit loop with one source-control model whose commands execute where the repository lives.

## Scoped deliverables

- Shared `RepositoryClient`, repository/status/diff models, and repository-scoped operation serialization.
- Local Git client using `Foundation.Process`; remote Git capabilities in the Rust agent and typed Swift client.
- Porcelain v2 NUL-delimited status parser, branch/detached state, worktree/submodule awareness, and debounced external refresh.
- Files/Changes sidebar mode, Changes and Staged Changes sections, unified diff viewer, open changed file, file-level stage/unstage.
- Editable subject/body and `git commit -F -`; hook output, failures, cancellation, and repository trust prompt before first hook-capable action.

## Explicit non-goals

- AI generation, hunk staging, history/blame, rebase, destructive reset/clean, advanced conflict resolution, GitHub PR UI, or credential management replacement.
- Persistent local Git subprocesses or shell command construction.

## Owned paths

- Domain/local owner: `Rafu/Git` shared models, process runner, local client/parser, Git tests.
- Remote Git owner: remote-agent Git capabilities, `Rafu/Git/RemoteGitClient.swift`, protocol tests.
- UI owner: source-control/diff/commit views under `Rafu/Git` plus sidebar integration adapters.
- Trust/hooks owner: `Rafu/Security/WorkspaceTrustStore.swift`, hook-output/error models and tests.
- Integration owner controls `WorkspaceSession.RepositoryState`, sidebar composition, and shared remote protocol version.

## Locked decisions

- Local and remote Git share one domain/UI model; remote Git runs remotely.
- Use stable machine output, NUL parsing as bytes, argument arrays, and `--` before paths.
- Index-changing operations serialize per repository; stdout/stderr drain concurrently.
- Initial staging is file-level only.
- Hook-capable commit requires contextual workspace trust; output remains visible.

## Open blockers to resolve

- Concrete repository trust persistence and first-commit explanation UX.
- Bounded Git timeout/cancellation policy, especially for hooks.
- Diff size/line limits and large-diff presentation behavior.
- Exact readable-but-nonexecuting treatment for conflict states.

## Required project references

- [`../../references/project-structure.md`](../../references/project-structure.md)
- [`../../references/build-and-run.md`](../../references/build-and-run.md)
- [`../../references/concurrency.md`](../../references/concurrency.md)

## Required skills and capabilities

- `.agents/skills/swift-concurrency-pro` for process draining, serialization, cancellation, and remote operations.
- `.agents/skills/design-an-interface` before locking repository, diff, process-error, and trust interfaces.
- `.agents/skills/swiftui-expert-skill` for sidebar/diff state, stable identity, and performance.
- `.agents/skills/apple-design` for scope visibility, immediate progress feedback, and restrained commit status.
- `build-macos-apps:swiftui-patterns` for Changes mode, commands, and commit form.
- `build-macos-apps:build-run-debug` and `build-macos-apps:telemetry` for real Git/hook verification; use `build-macos-apps:test-triage` only after a failure.
- `.agents/skills/swiftui-pro` for a focused source-control accessibility/performance review.

## Worktree decomposition and integration order

1. Domain owner freezes status/diff/path/error models and repository operation semantics.
2. Local Git/parser and remote-agent Git worktrees proceed with shared byte fixtures.
3. Integrate local client and edge cases before remote parity.
4. Integrate remote client/cancellation, then source-control UI and diff viewer.
5. Integrate staging/commit and trust/hooks last.
6. Run the same behavioral suite against local and SSH repositories.

## Verification and measurements

- No initial commit, detached HEAD, worktree `.git` file, rename/delete/untracked, conflicts, submodules, mixed staged/unstaged file, Unicode/newline filenames, missing Git, failing/prompting/slow hooks, and remote disconnect.
- Byte-level parser fixtures for porcelain v2 and NUL-delimited paths.
- Confirm index operations serialize and canceled/failed operations refresh to authoritative state.
- Confirm zero persistent local Git subprocesses and bounded diff memory for multi-megabyte fixtures.
- Verify diff colors plus non-color labels, keyboard access, VoiceOver, and external Git refresh.
- End-to-end local and SSH edit → review → stage → commit.

## Exit criteria

- Local and SSH repositories accurately show branch, staged, unstaged, untracked, conflict, worktree, and submodule state.
- File-level stage/unstage and editable commit succeed in both workspace types.
- Mixed staged/unstaged files are not misrepresented.
- Hook output/errors remain visible and never freeze the UI.
- Remote loss cancels cleanly without corrupting source-control state.

## Documentation handoff

Record command arguments, parser byte grammar, repository/trust rules, timeout policy, remote Git capability version, edge-case fixtures, diff limits, and measured process/memory behavior. Hand Phase 4 exact diff-scope APIs and staged-state semantics.
