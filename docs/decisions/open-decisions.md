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

## Meetings (2026-11-22)

Owners and context are in [`meetings.md`](../plans/phases/meetings.md) and the three Meetings decision records
([`0046`](0046-meeting-agent-without-visible-terminal.md), [`0047`](0047-meetings-scope-app-data-storage-and-agent-access.md),
[`0048`](0048-meeting-capture-and-on-device-speech.md)).

- Who writes the meeting summary, and when. An automatic send at Stop is against "keep AI explicit".
- The exact argument arrays for the hidden meeting agent, and whether a stricter "no tools, text on standard input" run
  is the default.
- A per-meeting "Let agents read this meeting" switch, or the Settings switch only.
- Whether "Open Folder..." in the Meetings window opens a new window or changes the same one.
- How long to keep meeting audio and transcripts.
- Whether Command-Shift-M works from the menu only, or system-wide.
- How Meetings looks on macOS 15: a "Needs macOS 26" message, or hidden.
- Which Rafu terminals get the Rafu tools for meetings.
- SpeakerKit memory at 2 hours; live text on two streams; permission behaviour after a rebuild; behaviour on macOS 26.
- The NVIDIA model licence answer for the later Nemotron option.

The full original list remains in product plan §20. Update this file and add an ADR when a choice is resolved.
