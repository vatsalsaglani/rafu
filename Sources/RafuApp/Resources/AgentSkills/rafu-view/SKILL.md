---
name: rafu-view
description: Show native views (tables, charts, stats, checklists, file links) on a Rafu Ensemble with the view_render and view_update tools, or by voice with show_view. Use with the json-render-swift-use skill for the spec language.
---

# Views on a Rafu Ensemble

Read the `json-render-swift-use` skill for the spec language, the standard components and the charts. This file adds only what is Rafu-specific. The `view_render` tool description lists the exact component vocabulary of this Rafu version.

## Tools

- `view_render { title?, spec, near? | x?, y? }` adds a view card. `spec` is `{root, elements, state?}`, at most 48 KiB per call; grow it with `view_update` patches. The result has `node_id`.
- `view_update { node_id, spec | patches | reset: true }`. Give exactly one. `patches` is JSON Lines, one `{op, path, value}` per line, against the current spec. A changed spec resets the view's state. Use `node_update` to rename or move the card.
- Voice: `show_view` takes the same spec keys flat beside `title`, `node` and `reset`.
- A card holds at most 256 KiB of spec and an Ensemble at most 50 views.

## Rafu components

FileLink{path,line?,label?} · CardLink{node,label?} · TerminalStatus{node} · AgentStatus{node} · DiffSummary{files} · IconLibraryIcon{pack,icon,size?} · KeyValue{items} · Timeline{events} · Stat{label,value,delta?,unit?,intent?} · Markdown{text} · Mermaid{source} · Code{text,language?} · Callout{kind,title?,text} · Checklist{items} · Questions · FileTree · Figure

`path` is relative to the workspace root. `node` is a node id or title from `ensemble_describe`.

## Actions you may name in `on`

`open_file {path, line?}`, `focus_node {node}`, `open_url {url}` (https only; Rafu asks the user), and the built-in state actions: `setState`, `pushState`, `removeState`, `validateForm`, `toggleState`, `incrementState`. Nothing in a view starts a process or types into a terminal.

## Agent control

- Off: refused. Tell the user; do not retry.
- Ask: the user approves in Rafu. The approval shows the title, the element count and the component types, never your text. A `pending_approval` result has a `request_id` for `action_status`.
- Allow: runs at once.
- Every view change is one undo step, and the notice offers Undo.

## Errors

An invalid spec comes back as `Invalid value for "spec": …` with the validator's codes, element ids and types. Fix those elements and call again once. Do not resend the same spec.

## Images

`Image {src}` with an `https` source shows a placeholder until the user allows images from the web (for this Ensemble, for that host, or for all in Settings). Prefer workspace paths, and `data:` URLs for small icons.

## State and Reset View

The view's state is saved with the Ensemble and is reset when the spec changes. Keys that start with `_` and password inputs are never saved. The user has Reset View; `view_update { reset: true }` does the same.

## Good views

- One number: `Stat`. Rows: `Table`, with `rows` bound to state so you can patch them. A series: a chart. Steps: `Timeline`. Files: `DiffSummary` or `FileLink`.
- Keep a view under 60 elements. Put data in `state` and bind it; patch `/state/...` to update.
- See [references/examples.md](references/examples.md) for three complete specs.
