# Charts (15)

Contents: the list, variants, shared props, rules that keep charts simple, budgets, selection, nesting, aggregation.

Rafu includes all 15 charts. Each chart is its own component type with a few props; there is no "Chart" with a `kind` switch. A chart has no children. The block below lists the charts of the upstream package.

```text
AVAILABLE COMPONENTS (15):

- BarChart: { data: Array<Record<string, unknown>> | $state, x: string, y: string, series?: string, orientation?: "vertical" | "horizontal", layout?: "grouped" | "stacked" | "normalized", sort?: "none" | "asc" | "desc", limit?: number, format?: string, selection?: $bindState, ...shared } - Bars from zero. One hue unless series is set.
- LineChart: { data, x: string, y: string, series?: string, curve?: "linear" | "monotone" | "step", points?: "auto" | "always" | "never", ...shared } - Trend over an ordered x axis.
- AreaChart: { data, x: string, y: string, series?: string, layout?: "overlap" | "stacked" | "normalized", ...shared } - Filled trend.
- PieChart: { data, label: string, value: string, donut?: boolean, center?: string, maxSlices?: number, ...shared } - Parts of a whole, at most 6 slices. [slots: center]
- Gauge: { value: number, min?: number, max?: number, label?: string, unit?: string, target?: number, bands?: Array<{ to: number, intent: "good" | "warn" | "risk" }>, style?: "arc" | "ring" | "linear", ...shared } - One value against a range.
- Sparkline: { values: Array<number>, intent?: "good" | "warn" | "risk" | "info", emphasis?: "last" | "max" | "none" } - Tiny trend without axes.
- ScatterChart: { data, x: string, y: string, series?: string, size?: string, trend?: "none" | "linear", ...shared } - Two numeric fields; size makes a bubble chart.
- Heatmap: { data, x: string, y: string, value: string, scale?: "sequential" | "diverging", ...shared } - Two categories and a value.
- Histogram: { values: Array<number>, bins?: "auto" | number, unit?: string, mode?: "count" | "percent", ...shared } - Distribution of one numeric field.
- ComboChart: { data, x: string, bars: string, line: string, ...shared } - Bars and a line on one y axis.
- Waterfall: { data, label: string, value: string, start?: number, subtotals?: Array<string>, orientation?: "vertical" | "horizontal", ...shared } - A total built from steps, at most 12.
- Funnel: { data, label: string, value: string, show?: "value" | "percent" | "both", sort?: "none" | "desc", align?: "center" | "left", ...shared } - Stages that shrink, at most 8.
- BoxPlot: { data, group: string, values?: string, orientation?: "vertical" | "horizontal", ...shared } - Spread per group, at most 20 groups.
- Candlestick: { data, x: string, open: string, high: string, low: string, close: string, style?: "candles" | "ohlc", ...shared } - Price periods, at most 180.
- Treemap: { data, label: string, value: string, group?: string, maxDepth?: number, minLabelArea?: number, ...shared } - Many parts of a whole, at most 200 cells.
```

## Variants

| Component | Renders with | Variants |
|---|---|---|
| BarChart | `BarMark` | vertical, horizontal, grouped, stacked, normalized, ranked |
| LineChart | `LineMark` (+ `PointMark`) | single, multi, stepped |
| AreaChart | `AreaMark` | area, stacked, normalized |
| PieChart | `SectorMark` | pie, donut, donut with centre |
| Gauge | SwiftUI `Gauge` + arc style | arc, ring, linear with bands and target |
| Sparkline | `LineMark` / `AreaMark`, no axes | line, filled |
| ScatterChart | `PointMark` | scatter, bubble, linear fit |
| Heatmap | `RectangleMark` | grid, calendar |
| Histogram | `BarMark` + bins | count, percent |
| ComboChart | `BarMark` + `LineMark`, one y-axis | bars + line |
| Waterfall | `RectangleMark` steps + `RuleMark` connectors | vertical, horizontal, subtotals |
| Funnel | centred horizontal bars, percent between steps | centred, left-aligned, with percent |
| BoxPlot | `RectangleMark` + `RuleMark` + `PointMark` | vertical, horizontal, outliers |
| Candlestick | `RectangleMark` body + `RuleMark` wick | candles, OHLC |
| Treemap | squarified layout on `Canvas` | flat, grouped (depth 2) |

## Shared props

Every chart accepts these. Field names (`x`, `y`, `series`, `label`, `value`) name keys of each row in `data`.

| Prop | Meaning |
|---|---|
| `data` | Array of row objects, or `{ "$state": "/runs" }` |
| `x`, `y` | Field names for the axes |
| `series` | Field that splits rows into series (adds categorical colours and a legend) |
| `label`, `value` | Field names for charts of parts (Pie, Funnel, Waterfall, Treemap) |
| `format` | `number`, `compact`, `percent`, `currency:<CODE>` (for example `currency:USD`), `duration`, `bytes` |
| `unit` | Unit text, on the axis or in the caption |
| `xDomain`, `yDomain` | `[min, max]` |
| `referenceLines` | `[{ "value", "label", "intent" }]`; give an `intent` only with a `label` |
| `legend` | `auto`, `bottom`, `trailing`, `hidden` |
| `height` | `compact` (96 pt), `regular` (160 pt), `tall` (240 pt) |
| `emptyText` | Text when `data` is empty |
| `selection` | `{ "$bindState": "/picked" }`; the chart writes the selected x value or slice label |
| `summary` | A sentence for VoiceOver. A default is generated when absent |
| `variant` | `default`, `minimal` (no axes), `dense` (smaller type, for board cards) |
| `title`, `caption` | Text; slots `title` and `caption` take elements instead |

`intent` is `good`, `warn` or `risk` (also `warning`, `critical`, `info`). Slots: `title`, `caption`, `empty`, `tooltip`, `center` (donut and ring).

Rows with a missing `x` or a non-numeric `y` are skipped. A field whose values are all ISO-8601 dates becomes a time axis; points that arrive out of order are sorted.

## Rules that keep charts simple

- One series is one hue (the accent). Categorical colours appear only when `series` is set. A status colour appears only for a status, such as a failure or an over-budget value.
- Bars start at zero, always. Lines may start above zero; the axis then says so.
- Gridlines are horizontal hairlines with 3 to 5 ticks. No vertical grid.
- Numbers use tabular digits and the compact format (1.2k, 3.4 MB). Put units on the axis or in the caption, not on every tick.
- Pie: at most 6 slices, then "Other". Negative values are an error and the validator suggests a BarChart. A one-slice pie becomes a Gauge.
- No 3D, no gradients, no dual axes, no exploded slices, no animation loops.
- Waterfall: totals and subtotals are grey from the baseline; increases take the accent, decreases the warning hue, each with a sign. At most 12 steps.
- Funnel: one hue, widest first, percent between rows. The validator rejects a value larger than the step before it unless `sort: "none"`.
- BoxPlot: at most 20 groups. Candlestick: up is good, down is critical with a hollow body; at most 180 periods. Treemap: at most 200 cells, depth at most 2; a single value becomes a Stat-like figure.
- A status colour is never the only signal; a sign, a label or a hollow shape goes with it.

## Budgets

| Limit | Value | Over the limit |
|---|---|---|
| Points per chart | 5,000 | Validator error. Line and Area over 1,000 points are downsampled (LTTB) before drawing |
| Series per chart | 12 | Validator error. After 8 series the palette cycles with a dash pattern |
| Pie slices | 6 shown, 12 accepted | Slices after 6 go to "Other". Over 12 is an error: use BarChart |
| Heatmap cells | 2,500 | Validator error |
| Waterfall steps / Funnel stages / BoxPlot groups | 12 / 8 / 20 | Steps and stages fold into "Other"; groups over 20 are an error |
| Candlestick periods / Treemap cells | 180 / 200 | Periods keep the last 180; cells fold into "Other" |
| Redraws | 1 per frame | The coalescer drops intermediate frames |

The chart rules run in the validator as catalog rules and give issues that name the element id and the rule, never values. Fix the spec when the validator reports one.

## Selection, accessibility, table

- `selection` writes the clicked x value (or slice label) to the bound path. Arrow keys move it when the chart has focus.
- Every chart sets an accessibility chart descriptor (VoiceOver audio graphs) and labels each mark, for example "Run 4210, 70 seconds".
- The context menu has "Show as Table", which shows the same rows in a table.

## Nesting

A chart can sit in a Card, a Tabs panel, a `repeat` (one Sparkline per row) or a Table cell. Series keep first-appearance order, so colours do not swap. Append points with a `view_update` patch such as `{"op":"add","path":"/elements/c1/props/data/-","value":{...}}`.

## Aggregation

Specs never contain code. Rafu's registered `$computed` functions turn state rows into chart rows: `groupSum` (rows, by, value), `countBy` (rows, by), `topN` (rows, by, value, n), `bucket` (rows, by, width or edges). Missing or wrong-typed args give undefined.

```json
"data": { "$computed": "topN", "args": { "rows": { "$state": "/runs" }, "by": "result", "value": "n", "n": 5 } }
```

