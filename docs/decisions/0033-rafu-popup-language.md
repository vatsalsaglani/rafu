# 0033. Rafu popup language

- Status: Accepted (owner direction), 2026-11-06
- Related: [ADR 0031](0031-card-header-tabs-and-themed-chrome.md),
  [ADR 0025](0025-workspace-canvas-and-app-previews.md)
- Phase: [`../plans/phases/issues-2026-11-06-fanout.md`](../plans/phases/issues-2026-11-06-fanout.md) (G5)
- Reference: [`../references/ui-design-language.md`](../references/ui-design-language.md) ("Popups")

## Context

The owner said the Ensemble popups "look very bad and are OS native". Open
Ensemble was a system `List` in a plain sheet: nothing was selected when it
opened, so Open stayed disabled; a disabled bordered "−" button showed as a
stray capsule; there was no empty state and no key hints. Confirmations were
`confirmationDialog` and `NSAlert`. The Icon Library was a titled utility
`NSPanel`, kept alive for the life of the app by a static reference. The
Command Palette already had a quiet card look, but only inside its own file.

## Decision

Rafu draws its own popups in one language, built from shared SwiftUI
components in `Sources/RafuApp/Support/RafuPopupComponents.swift`. There are no
web views and no new dependency.

- **Surface** (`RafuPopupSurface`, `.rafuPopupSurface(_:)`): `cardBackground`,
  `RafuMetrics.radiusPanel` (12, continuous), a 1 pt `borderStrong` hairline at
  0.5 opacity (full under Increase Contrast). No blur, so Reduce Transparency
  changes nothing. No new shadow: the workbench keeps exactly two
  (`RafuWorkbenchStyleContractTests`). In a system sheet the surface only fills
  the sheet (`.sheet` placement), because the sheet has its own corners.
- **Header** (`RafuPopupHeader`): leading SF Symbol, 15 pt semibold title
  (`.isHeader`), optional 12 pt subtitle, optional accessory, trailing `esc`
  hint, a hairline below.
- **Search** (`RafuPopupSearchField`): magnifying glass, plain field on
  `fieldBackground` with a focus ring, optional trailing key hint.
- **Rows** (`RafuPopupRow`): 32 pt, 16 pt icon slot, 13 pt title, 11 pt
  caption, trailing text or key hint. Hover is `hover`; selected is `selection`
  plus a hairline and the `.isSelected` trait. Selection never relies on colour
  alone.
- **Footer** (`RafuPopupFooter`): key hints on the left (hidden from
  VoiceOver), buttons on the right (`RafuSecondaryButtonStyle`,
  `RafuProminentButtonStyle`, `.defaultAction`/`.cancelAction`).
- **Confirmations** (`RafuConfirmPopup`): title, one sentence, actions,
  Cancel. **Return never destroys:** a destructive action is never the default
  action. Cancel is the default unless the caller names a non-destructive
  default (for example New Ensemble, Download). Escape always cancels.
- **Empty states** (`RafuEmptyState`) fill their space, per the AGENTS.md
  top-pinning rule.
- **Motion**: floating popups enter with a critically damped spring (response
  0.25), scale 0.98 → 1 plus a fade; Reduce Motion keeps only the fade.
- **Key hints** (`RafuKeyHint`) use the macOS modifier order ⌃ ⌥ ⇧ ⌘.

Migrated in this change: Open Ensemble (first row selected, Return opens,
Backspace or Delete… asks inside the same popup), the Icon Library (floating
borderless non-activating panel; arrow keys, Return, Escape; released on
close), the Add palette search field and key badges, New/Rename Ensemble,
Rename Card, Add Web App, Reload Ensemble?, Connect Cards/Edit Link, Ensemble
Shortcuts, Remove from Ensemble?, the agent-resume confirmation, Edit Label,
the icon-pack download confirmation, the embedded-image restore prompt, and the
Command Palette container.

What stays system:

- `NSOpenPanel` and `NSSavePanel`.
- System error alerts (for example "The Ensemble file could not be opened.").
- Native `Picker` and `Menu` controls inside a popup.
- The Files "Rename File" alert, for this round (G2 owned that file).

## Consequences

- One look across Ensemble popups; future popups compose the same components.
- Destructive confirmations no longer run on Return. Remove from Ensemble used
  to run on Return from the system dialog; now Return cancels.
- Navigation Peek is not migrated yet (outside G5's owned paths).
- Custom sheets lose the system alert icon and button layout; accessibility
  comes from the components (`.isHeader`, `.isSelected`, hints).

## Alternatives considered

- **Keep the system dialogs and only fix the defects.** Rejected: the owner
  asked for a different look.
- **A web-based popup layer.** Rejected: against the native-only and memory
  constraints (no per-document web views).
- **A blurred material surface.** Rejected: it fights Reduce Transparency and
  the flat workbench language.
