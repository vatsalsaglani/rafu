# The spec

Contents: shape, element fields, dynamic values, state paths, visibility, repeat, slots, watch, limits, validate.

## Shape

A spec is one JSON document. Elements are a flat map by id; a parent lists child ids.

```json
{
  "root": "card",
  "state": { "name": "Ada", "todos": [{ "id": "1", "title": "Ship" }] },
  "elements": {
    "card": { "type": "Card", "props": { "title": "Hello" }, "children": ["greet", "list"] },
    "greet": { "type": "Text", "props": { "text": { "$template": "Hi ${/name}" } }, "children": [] },
    "list": { "type": "Stack", "props": {}, "repeat": { "statePath": "/todos", "key": "id" }, "children": ["row"] },
    "row": { "type": "Text", "props": { "text": { "$item": "title" } }, "children": [] }
  }
}
```

| Key | Meaning |
|---|---|
| `root` | Id of the top element |
| `elements` | Map of id to element |
| `state` | Optional object that seeds the state model |

## Element fields

| Field | Type | Notes |
|---|---|---|
| `type` | string | A component name from the catalog |
| `props` | object | Component props; values may be dynamic expressions |
| `children` | string array | Child ids. Always write it; a leaf has `[]` |
| `slots` | object | Slot name to child ids, for example `{ "header": ["h"] }` |
| `visible` | condition | Show or hide the element |
| `on` | object | Event name to one action binding or an array of bindings |
| `repeat` | object | Render the children once per item of a state array |
| `watch` | object | State path to action binding(s), fired when the value changes |

`visible`, `on`, `repeat` and `watch` belong on the element, never inside `props`. The validator reports `visible_in_props`, `on_in_props`, `repeat_in_props` and `watch_in_props`.

An unknown element key is dropped and reported as a decode warning. `Spec.decode` accepts one `on` or `watch` binding object and stores it as a one-item array.

## Dynamic values

Any prop value can be an expression. Eight are built in; custom directives (for example `$format`) are the ninth kind.

| Expression | Reads | Notes |
|---|---|---|
| `{ "$state": "/path" }` | State at the path | One-way read. A missing path is undefined |
| `{ "$bindState": "/path" }` | State at the path | Two-way: the component writes back. Put it on the natural value prop (`value`, `checked`, `pressed`, `selected`, `page`) |
| `{ "$item": "field" }` | Field of the current repeat item | `""` is the whole item. Only inside `repeat` |
| `{ "$bindItem": "field" }` | Same field, with write-back | Two-way inside `repeat` |
| `{ "$index": true }` | Index of the current repeat item | Zero-based |
| `{ "$cond": C, "$then": A, "$else": B }` | Picks A or B | `C` uses the visibility syntax; A and B may be expressions |
| `{ "$computed": "fn", "args": { ... } }` | A function Rafu registered | Unknown name gives undefined. Specs never carry code |
| `{ "$template": "Hi ${/user/name}" }` | String with state values | `${/abs}` reads state; `${field}` reads the repeat item first, then `/field` |
| `{ "$format": "currency", "value": ... }` | A custom directive | Only registered directives resolve. See below |

Standard directives:

```json
{ "$format": "currency", "value": { "$state": "/cart/total" }, "currency": "USD" }
{ "$format": "date", "value": { "$state": "/post/createdAt" }, "style": "relative" }
{ "$count": { "$state": "/cart/items" } }
{ "$join": { "$state": "/tags" }, "separator": ", " }
{ "$pluralize": { "$state": "/cart/itemCount" }, "one": "item", "other": "items", "zero": "no items" }
```

`$format` takes `date | currency | number | percent`, plus optional `locale`, `currency` (default `USD`), `notation` (`compact`) and `style` (`relative`). Upstream `$math`, `$concat`, `$truncate`, `$t` are not shipped. `$cond` and `$template` cover most needs.

Use `$bindState` for inputs, `$state` for display. Use dynamic props instead of two elements with opposite `visible` conditions when only a prop differs.

## State paths

Paths are RFC 6901 JSON Pointers: `/todos/0/title`.

- `~1` means `/` and `~0` means `~` inside a token.
- `-` as the last token of a patch path appends to an array.
- A leading slash is optional; `""` and `/` are the root.
- `__proto__` is refused everywhere.
- No dot notation and no `.length`: `/todos.length` is wrong. Make unique ids with `"$id"` in `pushState` values.

## Visibility

```jsonc
{ "$state": "/tab" }                          // truthy
{ "$state": "/tab", "not": true }             // falsy
{ "$state": "/tab", "eq": "home" }            // eq, neq
{ "$state": "/count", "gt": 3 }               // gt, gte, lt, lte (numbers)
[ cond, cond ]                                // all must hold
{ "$and": [ cond, cond ] }                    // explicit and
{ "$or": [ cond, cond ] }                     // any
true                                          // always; false: never
```

- Use one comparison per condition. Several are accepted with a decode warning; upstream precedence `eq > neq > gt > gte > lt > lte` keeps one.
- A condition object uses exactly one subject: `$state`, `$item` or `$index`. Never mix them in one object.
- `$item` and `$index` conditions work only on an element that also has `repeat`; they filter rows.
- A shape the runtime cannot evaluate is hidden, and the validator reports `invalid_visible`. (Upstream sometimes shows it by accident; Rafu hides it.)
- For a first tab that shows when nothing is selected yet, use `$or`: `{ "$or": [{ "$state": "/tab", "eq": "home" }, { "$state": "/tab", "not": true }] }`.

## Repeat

```json
"list": { "type": "Stack", "props": {}, "repeat": { "statePath": "/todos", "key": "id" }, "children": ["row"] }
```

- The element renders once as the container; its `children` render once per array item.
- `key` is an item field that gives each row a stable identity. Use it when rows can be added, removed or reordered.
- Inside the children: `$item`, `$index`, `$bindItem`, and `${field}` in `$template`.
- A non-array at `statePath` renders nothing. More than 500 rows is capped (`maxRepeatRows`).
- Action params inside a row: `{ "$item": "field" }` resolves to the absolute state path (for example `/todos/2/done`), so it can feed `setState`. `{ "$index": true }` resolves to the index number.
- Filtered rows: put `repeat` and `visible: { "$item": "status", "eq": "todo" }` on the same element.
- A `$state` condition on a `repeat` element hides the whole container; an `$item` or `$index` condition filters rows.

Nested lists: the inner `repeat` reads an array from the enclosing item.

```json
"outer": { "type": "Stack", "props": {}, "repeat": { "statePath": "/posts", "key": "id" }, "children": ["inner"] },
"inner": { "type": "Stack", "props": {}, "repeat": { "statePath": { "$item": "comments" }, "key": "id" }, "children": ["comment"] }
```

`{ "$item": "" }` repeats over the enclosing item itself. This form is valid only inside another repeat (`repeat_item_outside_scope` otherwise). Writes through `$bindItem` go to the absolute path of the row, also in nested repeats.

## Slots

`children` is the default slot. A component can declare more slots; fill them with a top-level `slots` object:

```json
"card": { "type": "Card", "props": { "title": "Plan" }, "children": ["body"], "slots": { "footer": ["actions"] } }
```

Never use `slots.default`. Every listed id must exist. Slot names come from the catalog (`ComponentDefinition.slots`); a name the component does not declare is journaled once and ignored. Common names: `header`, `footer`, `leading`, `trailing`, `empty`, `loading`, `error`; charts add `title`, `caption`, `tooltip`, `center`.

## Watch

```json
"country": {
  "type": "Select",
  "props": { "label": "Country", "name": "country", "options": ["US", "UK"], "value": { "$bindState": "/form/country" } },
  "watch": { "/form/country": { "action": "setState", "params": { "statePath": "/form/city", "value": "" } } },
  "children": []
}
```

A watcher fires when the value at the path changes, not on first render. Use it for cascading fields. In Rafu it can run only the actions that the `view_render` tool description lists.

## Limits

| Limit | Value | Over the limit |
|---|---|---|
| Spec size | 256 KiB | `spec_too_large` / decode error |
| Elements | 2,000 | `too_many_elements` |
| Nesting depth | 64 | `depth_exceeded`; the subtree renders as a calm fallback |
| Repeat rows | 500 | rows capped |
| Stream buffer | 64 KiB per partial line | stream error, last good frame stays |

Rafu sets tighter limits per call (48 KiB of spec per `view_render`) and per card; see the `rafu-view` skill.

## Validate

`view_render` and `view_update` validate the spec and return the issues as `Invalid value for "spec": ...`. Treat `unknown_component` and `invalid_props` as rejects. To learn a prop shape, render a small spec and read the error; do not read Rafu's source code.

Issue codes: `missing_root`, `root_not_found`, `empty_spec`, `missing_child`, `invalid_visible`, `visible_in_props`, `on_in_props`, `repeat_in_props`, `watch_in_props`, `repeat_without_children`, `repeat_item_outside_scope`, `repeat_state_mismatch`, `orphaned_element` (upstream); `unknown_component`, `invalid_props`, `cycle`, `depth_exceeded`, `too_many_elements`, `too_many_repeat_rows`, `spec_too_large`, `custom_rule` (Rafu runtime). Messages carry ids, paths and type names, never prop or state values.
