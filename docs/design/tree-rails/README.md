# The started-by tree's rails — design

Status: **built** on `frog/tree-design-pass`. Shots: `before/` and `after/`, each with 16 renders:
org and date grouping × two-line and compact × light and dark × plain and with a nested row
selected.

The brief: the sidebar's started-by tree "has rails and elbows already — it's underdrawn, not
missing. Cramped and faint." Reading the code first paid off: **one of the four problems was
described wrong, and two were worse than described.**

## What was actually wrong

### 1. The rail was absent from the org tree, not faint
The brief said `.quaternary` at 1 px. That was true of `TreeGuide` — but `TreeGuide` was only
drawn by the by-date list (`twoLineEntries`) and the compact list. The **org tree**
(`treeEntries` → `TreeRow`), which is the view the brief's screenshot came from, drew no guide
at all: its children were told apart by indent alone. See
`docs/design/tree-rails/before/tree-rails-org-two-line-selected-dark.png` — four nested levels,
not one rail.

So this was not a colour pass. There was nothing to brighten.

Fix: `SessionNesting.Guide` (rails, elbow, and "does this column continue below"), computed
once per list from its depths, and `TreeRails`, one view that all three list modes use.

### 2. The selection pill swallowed the guide
Real. Every row painted its background across its full width, indent included, so a selected
nested row's guide disappeared into the fill.

Fix: the selection fill is now an inset pill starting past the rails and their elbow
(`TreeRow.selectionFill`, `CompactSessionRow.selectionFill`). Rails draw on the sidebar's own
ground, outside the pill, so a selected row still says where it sits — visible in
`after/tree-rails-org-two-line-selected-dark.png`, where `level 3 worker` is selected and both
of its ancestor rails run past the pill.

### 3. Three indents for one tree
The brief said two (14 pt two-line, 8 pt compact). There was a third: the compact `+N done` row
used `(depth - 1) * 8 + 4`.

Fix: one function, `AttentionMetrics.leading(depth)`. Every list mode calls it; nothing else
computes an indent.

### 4. The depth clamp was in the model, not the view
The brief offered "indent however deep it goes, or show that it's clamped — you choose."
Reading the code: `SessionNesting.rows` and `indented` *emitted* `min(depth + 1, maxDepth)`. A
fifth-level worker was not merely drawn at depth 4 — it **was** depth 4 by the time any view saw
it. No view could have marked the clamp, because the information was already gone.

Fix: no clamp anywhere. Depth is reported truthfully; the view spends it. The first four levels
take a full 14 pt column, then each further level takes `56 / level` (11.2 at the fifth, 9.3 at
the sixth), easing to `minStep = 4` and never reaching zero.

That is the answer to the brief's choice: **indent by real depth, with narrowing steps** — the
clamp was destroying information at the source, so a "clamped" marker would have been a label on
a lie.

## Numbers that changed

| what | before | after |
|---|---|---|
| rail on the org tree | none | one per ancestor + an elbow into the row |
| rail colour | `.quaternary` (in the two lists that drew one) | `Tokens.line` (#2a2a2a dark / #e3e3e3 light) |
| indent, two-line | 14 pt | `AttentionMetrics.leading`: 14 → 11.2 → 9.3 … |
| indent, compact | 8 pt | the same function |
| indent, compact `+N done` | `(depth - 1) * 8 + 4` | the same function |
| depth cap | `maxDepth = 4`, applied in the model | none |
| selection fill | full row width | inset past the rails |

## Snapshots

`SidebarSnapshotTests.testRenderTreeRails` stages a six-deep chain (depths 0–5) plus a sibling
at depth 1, and renders org and date grouping × both modes × light/dark × plain/selected-nested.

Two honesty notes about the harness, because the first attempt at a "before" set was wrong:

- **A parallel session landed the implementation on this branch while I was still reading the
  pre-change code.** It committed the code, the shots and my snapshot test together at 15:11, so
  the `before/` PNGs in that commit were rendered *from changed source* — they showed rails that
  had not existed. The set here is regenerated from the parent commit (`092e4644`) in a separate
  worktree, with only the snapshot test added.
- **That first attempt was also contaminated by real data.** The parent commit has no fixture
  guard on `Library.cloudChanged`, so the 15 s cloud poll pasted the real account's rows over the
  staged fixtures mid-render (rows titled "ping" and "Frog Cloud" appeared in the shots). The
  `before/` set here uses the same DEBUG staging guard the change adds, applied to the parent
  commit, so the only difference between the two sets is the tree drawing.

## Files

- `apps/FrogKit/Core/SessionNesting.swift` — `Guide`, `guides(_:)`, no depth cap.
- `apps/macos/Frog/Views/AttentionRows.swift` — `AttentionMetrics`, `TreeRails`, `TreeRailRow`,
  `TreeRow.selectionFill`.
- `apps/macos/Frog/Views/Sidebar.swift` — all three list modes draw from `guides`; the compact
  row's `selectionFill`.
- `design/tokens.json` → `Tokens.line` (regenerated with `node design/generate.mjs`).
