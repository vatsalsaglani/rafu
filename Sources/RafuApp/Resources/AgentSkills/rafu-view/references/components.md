# Rafu components

Exact props and item shapes for the Rafu-only components. The `view_render` tool description lists the same names; its `Array<unknown>` props are explained here. Do not read Rafu's source code: use this file, the `json-render-swift-use` skill and the validator error.

Rules for all of them:

- Write `props` and `"children": []` on every element. Components marked "accepts children" (Callout, Checklist, Questions, FileTree) may list child ids; the others take none.
- An item that is not an object, or that lacks its required field, is skipped without an error. Check the shape yourself.
- Any prop value can be a `$state` or `$bindState` expression, for example `"items": {"$state": "/files"}`.
- `node` is a node id or an exact title from `ensemble_describe`. `path` is relative to the workspace root, with no leading `/` and no `..`.
- Counts and limits: at most 200 rows in KeyValue, Timeline and DiffSummary.
- Intent words: `neutral`, `info`, `good`, `warning`, `critical`. An unknown word counts as `neutral`. Intent shows with a sign and a word, not by colour alone.

Each example below is a full `spec` that `view_render` accepts.

## FileLink

`{ path: string, line?: number, label?: string }`. A chip; a press opens the file in Rafu. An absolute path or a path that leaves the workspace shows as text only. `line` is a whole number. `label` replaces the shown text.

```json
{"root": "f", "elements": {"f": {"type": "FileLink", "props": {"path": "Sources/App/Main.swift", "line": 40, "label": "Start here"}, "children": []}}}
```

## CardLink

`{ node: string, label?: string }`. A chip that focuses another card on this Ensemble. The default text is the card's title. A node that is not on the Ensemble shows dimmed.

```json
{"root": "c", "elements": {"c": {"type": "CardLink", "props": {"node": "Notes", "label": "Open the notes"}, "children": []}}}
```

## TerminalStatus

`{ node: string, title?: string }`. Read only. Shows a terminal card's state: Idle, Running, Exited, Stopped, Unavailable, or the agent state when an agent runs there. `node` must name a terminal card, else it shows "Not found".

```json
{"root": "t", "elements": {"t": {"type": "TerminalStatus", "props": {"node": "Claude 1"}, "children": []}}}
```

## AgentStatus

`{ node: string, agent?: string }`. Read only. Shows the agent in a terminal card and its state. `agent` replaces the shown agent name.

```json
{"root": "a", "elements": {"a": {"type": "AgentStatus", "props": {"node": "Claude 1", "agent": "Reviewer"}, "children": []}}}
```

## DiffSummary

`{ files: Array<{ path: string, added: number, removed: number }> }`. Changed files with line counts. You supply the numbers; Rafu runs no Git command. `added` and `removed` are whole numbers from 0 to 9,999,999 (a missing or negative value counts as 0). `path` chips open files. With more than one file a total row shows.

```json
{"root": "d", "elements": {"d": {"type": "DiffSummary", "props": {"files": [{"path": "Sources/App/Main.swift", "added": 12, "removed": 3}, {"path": "Tests/MainTests.swift", "added": 30, "removed": 0}]}, "children": []}}}
```

## IconLibraryIcon

`{ pack: string, icon: string, size?: "sm" | "md" | "lg" }`. An icon from the user's imported icon packs. Get `pack` and `icon` from the `icon_search` tool; a pair that does not exist shows a placeholder. Sizes: sm 16, md 28 (default), lg 48 points.

```json
{"root": "i", "elements": {"i": {"type": "IconLibraryIcon", "props": {"pack": "my-pack", "icon": "database", "size": "md"}, "children": []}}}
```

## KeyValue

`{ items: Array<{ key: string, value: string | number | boolean }> }`. A two-column list of facts. A `key` or `value` of another type (object, array, null) shows "—". Not editable.

```json
{"root": "kv", "elements": {"kv": {"type": "KeyValue", "props": {"items": [{"key": "Branch", "value": "main"}, {"key": "Tests", "value": 412}, {"key": "Clean", "value": true}]}, "children": []}}}
```

## Timeline

`{ events: Array<{ time: string, title: string, text?: string, intent?: Intent }> }`. Events on a vertical rail, in the order given (write oldest first). `time` is free text such as "10:42" or "Mon". `text` is a second line.

```json
{"root": "tl", "elements": {"tl": {"type": "Timeline", "props": {"events": [{"time": "10:42", "title": "Build started"}, {"time": "10:49", "title": "Tests failed", "text": "2 failures in Voice", "intent": "critical"}]}, "children": []}}}
```

## Stat

`{ label: string, value: string | number, delta?: string, unit?: string, intent?: Intent }`. One key figure. `value` is a string or a number (an object or array shows "—"). `delta` is text such as `"+12%"` or `"-3"`; a leading `+` or `-` adds an arrow. `intent` colours the delta and adds an icon and a word.

```json
{"root": "s", "elements": {"s": {"type": "Stat", "props": {"label": "Tests", "value": 412, "delta": "+12", "intent": "good"}, "children": []}}}
```

## Markdown

`{ text: string }`. Prose: headings, lists, tables, links, inline code.

```json
{"root": "m", "elements": {"m": {"type": "Markdown", "props": {"text": "## Plan\n\n- Fix the parser\n- Add a test"}, "children": []}}}
```

## Mermaid

`{ source: string }`. The diagram text without code fences. Flowchart, sequence, class, state, ER and XY chart draw; other kinds show their source.

```json
{"root": "g", "elements": {"g": {"type": "Mermaid", "props": {"source": "flowchart LR\n  A[Agent] --> B[Rafu]"}, "children": []}}}
```

## Code

`{ text: string, language?: string }`. A code block. `language` is a fence name such as `swift` or `json`. Text over 64 KiB is cut.

```json
{"root": "c", "elements": {"c": {"type": "Code", "props": {"text": "let answer = 42", "language": "swift"}, "children": []}}}
```

## Callout

`{ kind?: "note" | "tip" | "info" | "warning" | "risk" | "decision", title?: string, text?: string }`. Accepts children (for example a `Markdown`) for a longer body; `text` is a one-line body.

```json
{"root": "c", "elements": {"c": {"type": "Callout", "props": {"kind": "risk", "title": "Migration", "text": "Back up the store first."}, "children": []}}}
```

## Checklist

`{ title?: string, items: Array<{ text: string, done: boolean }> }`. `text` may hold inline Markdown (bold, italic, code, links). `done` defaults to false. The header shows "N of M done". Read only, unless you bind `items` with `$bindState`: then the user can tick items and Rafu writes the whole array back to state.

```json
{"root": "c", "state": {"todo": [{"text": "Write the spec", "done": true}, {"text": "Run the tests", "done": false}]}, "elements": {"c": {"type": "Checklist", "props": {"title": "Release", "items": {"$bindState": "/todo"}}, "children": []}}}
```

## Questions

`{ title?: string, items: Array<{ text: string, options: Array<string> }> }`. Numbered review questions, each with its answer options. Display only: the user cannot pick an option here, so use `Radio` or `Select` with state for an answer you need back.

```json
{"root": "q", "elements": {"q": {"type": "Questions", "props": {"title": "Open questions", "items": [{"text": "Which store?", "options": ["SQLite", "Files"]}]}, "children": []}}}
```

## FileTree

`{ title?: string, entries: Array<{ path: string, depth?: number, action?: string, note?: string }> }`. Planned or finished file changes. `depth` is a whole number from 0 to 16 and sets the indent. `action` is a short word shown before the path: `add`, `modify`, `delete`, `rename` or `move`. A `path` that ends with `/` shows a folder icon. `note` is a short text after the path. Paths here are labels, not links; use `FileLink` for a path the user should open.

```json
{"root": "t", "elements": {"t": {"type": "FileTree", "props": {"title": "Files", "entries": [{"path": "Sources/", "depth": 0}, {"path": "Sources/Store.swift", "depth": 1, "action": "add", "note": "new store"}]}, "children": []}}}
```

## Figure

`{ src?: string, caption?: string, title?: string }`. In a view on an Ensemble, a Figure does not load an image: a local path shows "Image is outside the allowed folders" and an `https` source shows "Remote image not loaded". Use `Image { src, alt }` with a workspace path or a `data:` URL for a picture. Use Figure only for a titled caption slot you accept as text.

```json
{"root": "f", "elements": {"f": {"type": "Figure", "props": {"title": "Architecture", "caption": "Data flow between the app and the helper"}, "children": []}}}
```
