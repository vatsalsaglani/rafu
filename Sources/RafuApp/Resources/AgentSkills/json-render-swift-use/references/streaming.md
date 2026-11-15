# Streaming

Contents: the patch line format, the order to write in, edits.

A spec can be built or changed with JSON Patch (RFC 6902) lines. In Rafu, `view_update { node_id, patches }` takes these lines, one `{op, path, value}` per line, against the current spec. `view_render` takes the whole spec.

## JSONL patch lines

```jsonl
{"op":"add","path":"/root","value":"card"}
{"op":"add","path":"/elements/card","value":{"type":"Card","props":{"title":"Open tasks"},"children":["list"]}}
{"op":"add","path":"/elements/list","value":{"type":"Stack","props":{},"repeat":{"statePath":"/tasks","key":"id"},"children":["task"]}}
{"op":"add","path":"/state/tasks","value":[]}
{"op":"add","path":"/state/tasks/0","value":{"id":"1","title":"Write the spec","done":false}}
```

- One JSON object per line, no markdown, no code fence, no blank-line separators needed.
- Operations: `add`, `remove`, `replace`, `move` and `copy` (need `from`), `test`. `add` is the common one; `add` on an object key creates or replaces it.
- Paths are JSON Pointers into the spec: `/root`, `/elements/<id>`, `/elements/<id>/props/title`, `/state/<path>`.
- `-` as the last token appends: `{"op":"add","path":"/state/tasks/-","value":{...}}`. A chart can grow with `/elements/c1/props/data/-`.
- A path with `__proto__` is refused.

## Order

1. `/root` first, then elements (parents before children), then `/state`.
2. Every element has `type`, `props` and `children`. Leaves use `"children": []`.
3. Create a state array first (`"value": []`), then append items one by one.
4. Do not leave a child id that points at no element; the validator reports `missing_child`.

## Edit an existing spec

To change a spec, send patches against it with `view_update`: `replace` an element, `remove` one, `add` a new one. Merge (RFC 7396) and diff edit modes are not supported. A changed spec resets the view's state.
