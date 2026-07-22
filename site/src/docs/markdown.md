---
title: Markdown & Mermaid
description: First-class Markdown with a native preview — no per-document WebView.
---

# Markdown & Mermaid

Markdown is a first-class document type in Rafu — fitting, for an app whose users live
next to agents that read and write Markdown all day.

## Edit / Split / Preview

Every `.md` document carries a mode control:

```text
[ Edit | Split | Preview ]
```

Split (source left, live preview right) is the default, collapsing to Edit on narrow
windows. The default is configurable, and the last mode is remembered per file.

## Native rendering, honestly bounded

The preview parses GFM and renders to native text — **no per-document `WKWebView`**.
Each WebView costs a content process worth tens of megabytes; Rafu spends that budget
on your files instead.

The supported subset:

- Headings, emphasis, lists, task lists
- Tables, block quotes, thematic breaks
- Fenced code blocks — highlighted with the same syntax engine and theme tokens as the editor
- Strikethrough and autolinks

Deliberate limits:

- **Raw HTML blocks render as code.** No script execution of any kind.
- **Remote images are blocked by default**, with an explicit per-document allow action.
  Local workspace images load size-capped and lazily.
- Very large Markdown files fall back to Edit-only with a notice.

Split-mode scroll sync maps source blocks to rendered blocks — best-effort, and never
in the way of typing. Re-rendering is debounced and prioritizes the visible range.

## Mermaid diagrams

Fenced `mermaid` blocks render as native diagrams — no JavaScript engine, no WebView.

The native renderer supports a defined subset — **flowcharts** (`flowchart` / `graph`)
and **sequence diagrams** — drawn with a real 2D layout. Everything outside the subset,
or malformed input, renders as the source block with a visible *“diagram type not
supported in native preview”* notice, and native diagrams carry a *“Simplified native
preview”* badge. You will never see a blank canvas or a silently wrong diagram.

## Themed prose

Preview typography comes from the theme: Indigo and Khadi ship serif prose (New York)
with the editor's monospace face for code — the same pairing this site uses for its
display accents and code samples.
