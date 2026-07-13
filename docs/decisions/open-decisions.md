# Open decisions

These choices are intentionally unresolved. Do not turn a bootstrap placeholder into a permanent decision without an ADR.

## Before or during Phase 0

- Confirm the final reverse-DNS bundle identifier.
- Confirm the supported public macOS deployment target; the scaffold uses macOS 15 provisionally.
- Choose the TextKit 2 base after comparing a focused bespoke bridge, STTextView, and CodeEditSourceEditor.
- Choose the maintained Swift Tree-sitter integration and first grammar.
- Decide whether the production project remains package-first or gains an Xcode app project while preserving command-line reproducibility.
- Define which controls use the system accent and which editor/content semantics use Rafu's zari-gold theme token.

## Before Phase 1 polish

- Decide standalone-file window behavior.
- Lock the exact version-1 theme schema keys and migrate the historical Darn/Linen source artifacts.
- Resolve the whole-window theme boundary: whether native sidebar/toolbar/status chrome stays system material, consumes semantic tint only, or permits opaque theme backgrounds while preserving accessibility and future macOS behavior.
- Decide whether Changes is hidden or visible-but-disabled before Phase 3.
- Choose the filename/icon mapping and confirm icons remain non-themeable for v1.
- Choose the Markdown parser and final preview shortcut.
- Decide whether release builds always hot-reload user themes.
- Set large-file and remote chunk thresholds using measurements.

## Before or during SSH implementation

- Decide whether remote-agent installation needs an explanatory confirmation after host trust.
- Decide whether app-owned control masters are pooled per host or isolated per workspace initially.
- Define the remote symlink/root-capability policy.
- Choose the version-1 remote wire encoding.
- Decide default restoration and disclosure for dirty remote buffers.

## Before GitHub distribution

- Choose a repository license.
- Define supported contribution and security-reporting policies.
- Define GitHub CI runners and required checks.
- Define release artifacts, signing-secret handling, notarization, checksums, and update policy.

The full original list remains in product plan §20. Update this file and add an ADR when a choice is resolved.
