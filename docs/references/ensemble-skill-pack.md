# Bundled Ensemble coordinator skill

- **Applies to:** `Sources/RafuApp/Resources/EnsembleSkills/`,
  `ConductorSkillInstaller`, Settings → Ensemble, and coordinator verb updates
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-26

## Rule or observed behavior

Rafu ships `ensemble-with-rafu` as five read-only SwiftPM resources:

```text
ensemble-with-rafu/
  SKILL.md
  references/
    verbs.md
    file-formats.md
    patterns.md
    troubleshooting.md
```

`Package.swift` copies the parent `Resources/EnsembleSkills` directory once,
preserving the layout under `Bundle.module`. The catalog resolves that root
with:

```swift
Bundle.module.url(forResource: "EnsembleSkills", withExtension: nil)
```

The installer uses a code-declared manifest of exactly those five relative
paths. It never enumerates the resource directory to decide what to write.
Every component is validated, every source and existing destination is capped
at 1 MiB, and every destination is classified before any directory or file is
created. Fresh files publish through an atomic same-directory hard link;
confirmed replacements use Foundation's atomic write. Identical files are
reported as unchanged. Different files are returned as conflicts until the
user explicitly confirms replacement.

Two destinations are supported:

- **Claude Code:** `~/.claude/skills/ensemble-with-rafu/`.
- **Custom:** the user chooses a skills directory and Rafu creates
  `ensemble-with-rafu/` inside it.

Claude Code is the only vendor directory verified as a first-class target.
Rafu must not guess a Codex or other vendor's directory. Settings' folder
picker is the honest fallback until another path is verified. Every result
reports the exact resolved destination plus written, replaced, and unchanged
counts.

`SKILL.md` declares `targetsVerbVersion`. A load-time metadata parse drives the
Settings version line, and the test suite asserts:

```swift
targetsVerbVersion == LauncherIPCProtocol.ensembleVerbVersion
```

That equality is the version-drift tripwire. Verb coverage is intentionally
one-way: every case represented by the shipped `EnsembleInvocation` parser
must appear in `verbs.md`, while the document may also teach accepted mutating
verbs that a wave-2 parser does not implement yet.

When the CLI verb surface changes, update the authoritative
`ensemble-ipc-verbs.md` first, advance `ensembleVerbVersion` for a breaking
change, then mirror the grammar, JSON, states, token rule, and exit behavior
into the bundled `references/verbs.md`. Never invent a flag in the skill.
Update `targetsVerbVersion` last and let the drift test prove the bundle and
launcher agree.

## Why it matters

A coordinator skill survives context compaction and teaches a long-running
external CLI the same gates, budgets, and failure actions Rafu implements.
Bundling makes that material available offline; instantiate-never-edit
preserves the read-only source; classify-before-write and explicit conflict
confirmation prevent a Settings action from silently replacing a user's
customized skill. The version line turns stale coordination instructions into
an explicit warning instead of confusing command retries.

## Reproduction or evidence

`SkillPackTests` resolves the resource root through `Bundle.module`, reads all
five bounded files, parses `SKILL.md` with `ConductorFrontmatter`, proves the
version equality, and asserts parser verbs are present in `verbs.md`.

Installer tests cover a fresh five-file install, idempotent reinstall,
classify-before-write conflict refusal, confirmed replacement, unsafe
components, the custom destination description, and the exact Claude Code
path. `EnsembleSettingsTests` proves construction invokes no catalog provider,
metadata loads only from the explicit async load step, match/mismatch logic is
honest, and the model reports the exact install result.

## Verification

```bash
swift test --filter SkillPack
swift test --no-parallel --filter SkillPack
swift test --filter EnsembleSettings
swift build
swift test
swift test --no-parallel
./script/format.sh --fix
./script/format.sh --lint
```

## Related code, ADRs, and phases

- `Package.swift`
- `Sources/RafuApp/Conductor/Ensemble/ConductorSkillInstaller.swift`
- `Sources/RafuApp/Settings/EnsembleSettingsTab.swift`
- `Tests/RafuAppTests/Conductor/SkillPackTests.swift`
- `Tests/RafuAppTests/EnsembleSettingsTests.swift`
- [`ensemble-ipc-verbs.md`](ensemble-ipc-verbs.md)
- [`conductor-file-contracts.md`](conductor-file-contracts.md)
- [`C8-05-skill-pack-and-settings.md`](../plans/phases/conductor/C8-05-skill-pack-and-settings.md)
- [ADR 0018](../decisions/0018-conductor-external-agent-orchestration.md)
