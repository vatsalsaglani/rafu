# Choosing a component

Contents: the table, layout and forms, anti-patterns, defaults that look good.

Rule: spectacularly simple by default. Pick the plainest element that shows the data; the theme does the styling.

## Which element for which data

| The data is | Use | Not |
|---|---|---|
| One number with a label | A `Card` with a `Heading` (or a Stat-like Card row in a `Grid`) | A chart |
| Rows with a few columns | `Table` | A chart, or a stack of `Text` |
| A list of items with actions | `repeat` over a `Stack` row | Hand-copied elements |
| A series over time or order | `LineChart` or `AreaChart` (`BarChart` for few points) | `Table` of 200 rows |
| Compare a value across categories | `BarChart` (`ranked` or `horizontal` for long labels) | `PieChart` with more than 6 slices |
| Parts of a whole, up to 6 parts | `PieChart` (donut) | 3D, exploded slices |
| Many parts of a whole | `Treemap` | `PieChart` |
| Stages that shrink (a pipeline) | `Funnel` | `BarChart` |
| A total built from increases and decreases | `Waterfall` | `BarChart` |
| One value against a range or a budget | `Gauge` (use `bands` and `target`) | `Progress` when there is no range |
| A tiny trend inside a row or Card | `Sparkline` | A full `LineChart` |
| Two categories and a value | `Heatmap` | `Table` |
| Two numeric fields per item | `ScatterChart` | `LineChart` |
| Distribution of one numeric field | `Histogram` or `BoxPlot` (many groups) | `BarChart` |
| Prices over periods | `Candlestick` | `LineChart` of closes only |
| Bars and a line with one unit | `ComboChart` | Dual y-axes (not supported) |
| A task with progress 0 to 100 | `Progress` | `Gauge` |
| A status or short tag | `Badge` | Coloured `Text` |
| A message the user must read | `Alert` | `Text` with a colour |

## Layout

- `Card` groups related content. One `Card` per topic; do not nest more than two deep.
- `Stack` for rows and columns (`gap` token). `Grid` for 2 to 4 equal cells.
- `Tabs` with `visible` panels for sections that share space. `Accordion` or `Collapsible` for optional detail.
- `Dialog` for a choice that must finish before the user goes on; `Drawer` for a side task.
- `Separator` only where two groups need a visible split.
- `Heading` for section titles, `Text` for body. `Text` `muted` and `caption` for secondary lines.

## Forms

- One `Input` per fact. Give every field a `label` and a `name`.
- Bind every field with `$bindState`; add `checks` (`required`, plus one format check).
- One `Button` with `variant: "primary"` per view. The primary action is the one the user most likely wants.
- Use `Select` for 4 to 12 options, `Radio` for 2 to 4, `Switch` for an immediate setting, `Checkbox` for a choice that is submitted.
- Confirm destructive actions (`confirm` with `variant: "danger"`).

## Anti-patterns

- A pie with more than 6 slices, negative pie values, a one-slice pie.
- A dual-axis chart. Two units mean two charts.
- Colour as the only signal (a red number with no word or sign).
- A chart for one number, a table for one row.
- Props that restate the theme (colours, fonts, sizes). Props carry content and a choice of variant.
- Dozens of top-level cards. Group them, or use `Tabs`.
- Hand-written rows instead of `repeat`; state values written into both `props` and `state`.
- Long text in `Tooltip` or `Popover`. Put it in the page.
- Inventing a component name or an event name not in the list.

## Defaults that look right

Three to five props per element, only the content prop required. Card padding, stack gap and type sizes come from the theme. Status uses an icon, a word and a hue. Numbers use tabular digits. No spinners for known content; static placeholders hold the final layout.
