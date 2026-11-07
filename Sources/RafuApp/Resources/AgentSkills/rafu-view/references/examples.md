# rafu-view examples

Three complete `spec` objects for `view_render`. Each is valid against the Rafu catalog vocabulary in the `view_render` tool description.

## A row of stats

```json
{
  "root": "row",
  "elements": {
    "row": { "type": "Stack", "props": { "direction": "horizontal", "gap": "md" }, "children": ["tests", "time"] },
    "tests": { "type": "Stat", "props": { "label": "Tests", "value": { "$state": "/tests" }, "intent": "success" }, "children": [] },
    "time": { "type": "Stat", "props": { "label": "Duration", "value": { "$state": "/seconds" }, "unit": "s" }, "children": [] }
  },
  "state": { "tests": 412, "seconds": 38 }
}
```

## Failing tests by suite, bound to state

`columns` are header labels and `rows` is a 2D array of cell strings. Patch `/state/rows/N` later with `view_update` to change one row.

```json
{
  "root": "card",
  "elements": {
    "card": { "type": "Card", "props": { "title": "Failing tests" }, "children": ["table"] },
    "table": {
      "type": "Table",
      "props": { "columns": ["Suite", "Failing"], "rows": { "$state": "/rows" }, "sortable": true },
      "children": []
    }
  },
  "state": { "rows": [["Voice", "2"], ["Canvas", "1"]] }
}
```

## A change summary with file links

```json
{
  "root": "card",
  "elements": {
    "card": { "type": "Card", "props": { "title": "This change" }, "children": ["diff", "entry"] },
    "diff": {
      "type": "DiffSummary",
      "props": { "files": [{ "path": "Sources/App/Main.swift", "added": 12, "removed": 3 }] },
      "children": []
    },
    "entry": { "type": "FileLink", "props": { "path": "Sources/App/Main.swift", "line": 40, "label": "Start here" }, "children": [] }
  }
}
```
