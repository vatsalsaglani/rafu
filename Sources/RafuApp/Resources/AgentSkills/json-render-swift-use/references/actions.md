# Actions

Contents: binding shape, built-in actions, extra state actions, confirm, what an app gates.

## Binding shape

Events bind to actions in the element field `on`. The key is an event name the component declares (`press`, `change`, `submit`, `select`, ...).

```json
"on": {
  "press": {
    "action": "setState",
    "params": { "statePath": "/saved", "value": true }
  }
}
```

| Field | Meaning |
|---|---|
| `action` | A built-in action, or an action the tool description lists |
| `params` | Object; values may be expressions (`$state`, `$item`, `$index`, `$template`, ...) |
| `confirm` | A dialog the user must accept first |
| `onSuccess` | What runs after the handler succeeds |
| `onError` | What runs when the handler throws |
| `preventDefault` | Ask the app to skip its default behaviour for the event |

`on.press` may be one binding or an array. An array runs in order; if the user declines a `confirm`, the later bindings do not run.

Never put `action` or `actionParams` inside `props`. Never invent an event name: use the ones in the component's `[events: ...]` list.

## Built-in actions

These need no app code.

| Action | Params | Effect |
|---|---|---|
| `setState` | `statePath`, `value` | Writes `value` at `statePath`. An undefined value removes the path |
| `pushState` | `statePath`, `value`, `clearStatePath?` | Appends `value` to the array. Then sets `clearStatePath` to `""` |
| `removeState` | `statePath`, `index` | Removes the array item at `index` |
| `validateForm` | `statePath?` | Validates every registered field. Writes `{ "valid": bool, "errors": { "<field path>": ["message"] } }` to `statePath` (default `/formValidation`) |

`pushState` values may hold `{ "$state": "/path" }` (read current state) and `"$id"` (a new unique id). Add a todo and clear the field:

```json
"on": { "press": { "action": "pushState", "params": {
  "statePath": "/todos",
  "value": { "id": "$id", "title": { "$state": "/newTodo" }, "completed": false },
  "clearStatePath": "/newTodo"
} } }
```

Remove the current row: `{ "action": "removeState", "params": { "statePath": "/todos", "index": { "$index": true } } }`.

Set a field of the current row: `{ "action": "setState", "params": { "statePath": { "$item": "done" }, "value": true } }`. In a param, `$item` is the absolute state path of that field.

Use `pushState` and `removeState` for lists the user edits. Use `$bindItem` for a field the user changes directly.

Built-ins do not run `onSuccess` or `onError`. For a form, run `validateForm`, then show the submit button when `/formValidation/valid` is true.

## Extra state actions

`toggleState` and `incrementState` are Rafu additions, not upstream json-render. Another json-render renderer ignores them.

| Action | Params | Effect |
|---|---|---|
| `toggleState` | `statePath` | Flips a boolean. A missing or `null` value becomes `true` |
| `incrementState` | `statePath`, `by?` | Adds `by` (default 1). A missing or non-number value counts as 0 |

```json
"on": { "press": { "action": "toggleState", "params": { "statePath": "/menuOpen" } } }
```

## Confirm

```json
"confirm": {
  "title": "Delete this run?",
  "message": "The run leaves this list.",
  "confirmLabel": "Delete",
  "cancelLabel": "Keep",
  "variant": "danger"
}
```

`confirmLabel`, `cancelLabel` and `variant` (`default` or `danger`) are optional. `${/path}` in `title` and `message` reads state only. Every action honours `confirm`, built-ins too (upstream ignores it on built-ins). The app shows the dialog. Put `confirm` on destructive actions.

## Actions the app adds

A spec can only name actions the app registered. An unknown name does nothing, so use only actions the tool description lists. Rafu adds `open_file`, `focus_node` and `open_url`; the `rafu-view` skill describes them. Nothing in a spec runs code, makes a network call, reads a file or opens a window by itself; only the app's handlers do, and the user can see and decline them.

`onSuccess` (`{ "set": { "/path": value } }` or `{ "action": ..., "params": ... }`) and `onError` (the same, and the literal string `"$error.message"` becomes the error message) work for these app actions, not for built-ins.
