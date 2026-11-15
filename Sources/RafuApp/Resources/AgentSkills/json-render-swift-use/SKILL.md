---
name: json-render-swift-use
description: Author json-render specs for Rafu's native views: the JSON spec language, the 36 standard components, the 15 charts, state binding, repeat, visibility and actions. Use when you write or change a spec for the view_render or view_update tools, or choose a component or chart. Rafu's own components are in the rafu-view skill.
---

# json-render specs: write them for Rafu

Rafu draws a spec with swift-json-render, a native Swift runtime for the json-render specification (https://github.com/vercel-labs/json-render). You write a small JSON tree; Rafu draws it with native views. The catalog says which components and actions exist; Rafu owns the theme, the actions and every side effect. There is no web view and no code in a spec. Component names, prop names and action params are the upstream ones. You only author specs here: do not install or change the package, and do not read Rafu's source code. Rafu's own components (FileLink, KeyValue, Timeline, Checklist and others) are in the `rafu-view` skill, `references/components.md`.

## The spec in 20 lines

```json
{
  "root": "card",
  "state": { "name": "Ada", "todos": [{ "id": "1", "title": "Ship", "done": false }] },
  "elements": {
    "card": { "type": "Card", "props": { "title": "Hello" }, "children": ["greet", "list"] },
    "greet": { "type": "Text", "props": { "text": { "$template": "Hi ${/name}" } }, "children": [] },
    "list": { "type": "Stack", "props": { "gap": "sm" }, "repeat": { "statePath": "/todos", "key": "id" }, "children": ["row"] },
    "row": { "type": "Checkbox", "props": { "label": { "$item": "title" }, "name": "done", "checked": { "$bindItem": "done" } }, "children": [] }
  }
}
```

- `elements` is a flat map; a parent lists child ids in `children` (always present, `[]` for a leaf).
- `props` carry content. `visible`, `on`, `repeat`, `watch` and `slots` sit on the element, never inside `props`.
- Dynamic values: `$state`, `$bindState`, `$item`, `$bindItem`, `$index`, `$cond`, `$computed`, `$template`, and custom directives such as `$format`.
- `state` seeds the data the expressions read.
- Details: [references/spec.md](references/spec.md).

## Which component

| Need | Use |
|---|---|
| Group content | `Card`; rows and columns with `Stack`; equal cells with `Grid` |
| Text | `Heading`, `Text`, `Badge`, `Alert`, `Link` |
| Rows of data | `Table`; actions per row with `repeat` over a `Stack` |
| Sections that share space | `Tabs` with `visible` panels, `Accordion`, `Collapsible` |
| Modal task | `Dialog` or `Drawer` with `openPath` |
| Input | `Input`, `Textarea`, `Select`, `Checkbox`, `Radio`, `Switch`, `Slider`, `Toggle`, `ToggleGroup`, `ButtonGroup`, `DropdownMenu` |
| Do something | `Button` (`on.press`) |
| One number | A `Card` with a `Heading`, not a chart |
| A series, parts, stages, a range | A chart: see [references/choosing.md](references/choosing.md) |

## Rules that keep specs valid

1. Use only components and actions the catalog lists. Do not invent names, props or events.
2. Every element has `type`, `props`, `children`. Every id in `children` or `slots` must exist.
3. `visible`, `on`, `repeat`, `watch` go on the element, never in `props`.
4. Put `$bindState` on the natural value prop of an input (`value`, `checked`, `pressed`, `selected`, `page`). Inside `repeat`, use `$bindItem`.
5. Include `state` for everything the UI reads (`$state`, `$bindState`, `$item`, `repeat`). Use realistic sample data. Show data with `$state`, not by repeating it in props.
6. Render lists with `repeat` and a `key` field. Never copy an element per item. At most 500 rows.
7. State paths are RFC 6901 pointers (`/todos/0/title`). No dot notation, no `.length`. Make ids with `"$id"` in `pushState`.
8. Use `setState`, `pushState`, `removeState` and `validateForm` for state changes; add `confirm` to destructive actions. Other actions (`open_file`, `focus_node`, `open_url`) only as the `view_render` tool description lists them.
9. Patch order for `view_update`: `/root`, then elements, then `/state` patches, one patch per array item.
10. Keep it plain: three to five props, no colour or font props (the theme does that), one primary `Button` per view, status shown with a word and a sign, not colour alone.

## Check before you answer

- Walk the tree from `root`; every id resolves.
- Every input has `label`, `name`, a bound value and `checks`.
- Every `$bindItem`, `$item` and `$index` is inside a `repeat`.
- Charts follow [references/charts.md](references/charts.md) limits (pie at most 6 slices, no dual axis).
- `view_render` validates the spec ([references/spec.md](references/spec.md#validate)); treat `unknown_component` and `invalid_props` as rejects and fix them.

## Not supported

- YAML specs; the spec is JSON.
- Merge and diff edit modes; patch mode only.
- The `$math`, `$concat`, `$truncate` and `$t` directives; `$format`, `$count`, `$join`, `$pluralize` are shipped.
- Loading remote images; Rafu asks the user first.
- Components outside the 36, the 15 charts and Rafu's own components.

## References

- [references/spec.md](references/spec.md): element fields, the expressions, visibility, repeat, slots, watch, limits, validation.
- [references/actions.md](references/actions.md): buttons and forms: built-in actions, `toggleState`, `incrementState`, `confirm`.
- [references/streaming.md](references/streaming.md): patch lines for `view_update`, order, edits.
- [references/components.md](references/components.md): the standard components: props, extras, slots, events, notes.
- [references/charts.md](references/charts.md): the 15 charts, shared props, rules, budgets.
- [references/choosing.md](references/choosing.md): which element fits the data; anti-patterns.
- [references/security.md](references/security.md): what a spec cannot do; images, links, secrets.

## Source

Bundled from swift-json-render 0.22.0-alpha.3 (commit a319217c950cc55de0b31f884e8c32877e2b09ee), Apache License 2.0. See `LICENSE` and `NOTICE` in this folder. Rafu edited the text: install, upgrade and app-code sections are removed.
