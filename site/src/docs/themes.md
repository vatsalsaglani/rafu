---
title: Themes
description: Data-only JSON themes — Indigo and Khadi bundled, hot-reloaded on save.
---

# Themes

Rafu themes are **data-only JSON files** — fonts, colors, and syntax styles. No
scripting, no CSS, no code: a theme cannot execute anything. That gives you
Obsidian/Zed-style personalization without an extension runtime.

## Bundled: Indigo & Khadi

Two palettes, one identity. **Indigo** is indigo-dyed cloth at night; **Khadi** is
undyed handspun cotton in daylight; the **zari-gold** accent is the visible mending
thread through both. Rafu follows the system appearance by default — Indigo in dark
mode, Khadi in light — and you can pin any theme per appearance, or one for both.

This website runs on the same two palettes. The toggle in the navigation bar switches
between them, and every code sample here is highlighted with Rafu's own syntax themes.

## Locations and lifecycle

```text
Bundled:  Rafu.app/Contents/Resources/Themes/indigo.json, khadi.json
Yours:    ~/Library/Application Support/Rafu/Themes/*.json
```

User themes are watched and **hot-reloaded on save**: iterate by editing the JSON,
saving, and seeing the change — no restart.

Validation is forgiving but safe:

- Every color must be `#RRGGBB` or `#RRGGBBAA`
- Missing tokens inherit from the bundled theme of the same appearance — partial themes
  are legal
- A malformed theme falls back to the bundled default with a nonblocking warning —
  never a blank editor

## Schema shape

```json
{
  "$schema": "https://rafu.dev/schemas/theme/v1.json",
  "version": 1,
  "name": "Indigo",
  "id": "dev.rafu.theme.indigo",
  "appearance": "dark",
  "fonts": {
    "editor": { "family": "SF Mono", "size": 13, "lineHeightMultiple": 1.5 },
    "ui": { "family": "system", "size": 13 },
    "markdownPreview": { "prose": { "family": "New York", "size": 15 }, "code": "editor" }
  },
  "ui": { "appBackground": "#10141C", "accent": "#E3A857" },
  "editor": { "background": "#151A24", "cursor": "#E3A857" },
  "git": { "added": "#7CC08A", "modified": "#D2B958" },
  "diff": { "addedBackground": "#142E1D", "removedBackground": "#331D20" },
  "syntax": {
    "keyword": { "color": "#9D8CE8" },
    "comment": { "color": "#5F6980", "fontStyle": "italic" }
  }
}
```

## Semantic tokens, not per-language hacks

Syntax tokens are semantic — `keyword`, `function`, `type`, `string`, `comment`,
`markup.heading`… — and the syntax engine maps its captures onto them centrally. Write
one palette and every bundled language, the Markdown preview, the diff viewer, the
sidebar, and the status bar restyle coherently.

The same rule applies to Git and diff colors (`git.added`, `diff.removedBackground`…):
a theme restyles the whole window, not just the code canvas.

## Performance, by construction

Theme JSON is parsed **once** into cached color, font, and attribute tables keyed by
semantic token. Nothing on the typing path touches JSON, string keys, or color parsing;
a theme swap exchanges the tables and invalidates visible attributes only.

## Start your own

Copy `indigo.json` or `khadi.json` into your user themes folder, rename the `id`,
change one token, save. The fastest honest way to learn the schema is to fork a theme
that already respects its contrast budgets — body text and syntax tokens should meet
WCAG AA (≥ 4.5:1) against the editor background, and Git state should never be carried
by color alone.
