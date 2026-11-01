# Data model: reaching the values of selected items

Proposal, 22 October 2026. Not reviewed, not implemented.

This plan owns how code and the GUI reach the values of selected items: names, levels, positions
and how values of different levels combine. Every consumer uses the same rules: plots, the table
window, fits, `analyze` code and the REPL. How groups are formed belongs to [groups](groupings.md);
how values are stored belongs to [storage](storage.md); plot syntax belongs to the
[graphics grammar](graphics-grammar.md), which uses this model.

## The problem

Today a selection is one table with one row per item. Its columns are `id`, `label`, one column per
level of the collection tree, the metadata keys, and `data`, which holds each item's whole data.

- `data` appears next to the metadata as if it held one value per item. AlgebraOfGraphics offers
  it as a column, and `data.VoltageLow_V` fails.
- The columns of an item's data (a sweep's `VoltageLow_V`) cannot be plotted without first writing
  code that stacks the items' tables and copies metadata onto each row.
- Tree-level columns are named after the collection type, so all folder levels share the column
  `DirectoryCollection` and only the deepest folder survives.

An item's data is whatever the project's `read` or `process` returned: a table, a matrix, a number
or a value of the project's own type. The model must work for all of them without asking the
project to rename or restructure its data.

## Levels and paths

A selection is nested, like a Matlab struct array. Each name sits at one level:

```
selection                         one entry per item
├── label, Device, Chip, …        metadata: one value per item
└── data                          the item's data, as the project returned it
    ├── VoltageLow_V, …           if the data is a table: one value per row
    └── (the matrix itself)       if the data is a matrix: one value per entry
```

A **path** names a value by following this nesting: `:Device`, `:data.VoltageLow_V`, `:data`. The
path says where the value lives. Nothing else is named: a matrix is reached as `:data`, and its
rows and columns are reached by position.

The tree levels of the browser (folders, recipe collections) are metadata with real names: one
`folder` value with the relative path, such as `"72b/L/bigTLM"`, and the names a recipe gives its
levels, such as `wafer` and `device`.

## The rules

1. **A formula runs once per item.** Inside a formula, a path is that item's value: `:Device` is a
   string, `:data.VoltageLow_V` is a vector, `:data` is a matrix. Formulas are ordinary Julia.
2. **Items are independent.** Each item's mapped values are computed for that item alone, and the
   marks of all items are drawn together. Selected items may hold different kinds of data: only
   the values a mapping uses must exist for each item.
3. **The mark decides how an item's values are used.**
   - Marks of single observations (points, lines, bars): the values broadcast together, as in any
     Julia expression, and the result has one entry per point. `color=:Device` next to a column of
     the data gives each row its item's device; a mapping of only one-value-per-item values gives
     one point per item. A vector runs down a matrix's rows; a transposed vector (`:gate_V'`) runs
     along its columns. `axes(:data, 1)` is the row numbers and `axes(:data, 2)'` the column
     numbers. This works for square matrices too, where lengths cannot tell the sides apart.
   - Grid marks (heatmap, image, contour, surface): the matrix and its axes are taken whole, in any
     form Makie accepts, such as cell centres or cell edges.

   Marks belong to the [graphics grammar](graphics-grammar.md); this plan only fixes that the
   values reach them per item.

## Example 1: a table per item

Selected: three Vsweep files. Each item has metadata from the file header and a table:

```
metadata                     data (a table, about 200 rows)
Chip      72b                VoltageHigh_V  VoltageLow_V  CurrentHigh_A  CurrentLow_A  Time_s  Status
Site      L                  -3e-05         0.0           -1.1e-09       1.8e-09       0.21    0
Device    C2_50um            0.00012        8e-05         3.6e-09        -4.6e-09      0.31    0
gap_um    50                 …
```

One curve per file:

```julia
@plot mapping(:data.VoltageHigh_V, :data.CurrentHigh_A; color=:Device) * visual(Lines)
```

Row level, because both axes are columns of the data. `Device` is copied onto each row.

Current density, a formula that mixes levels:

```julia
@plot mapping(:data.VoltageHigh_V, :data.CurrentHigh_A ./ :Amesa_um2; color=:Device) * visual(Lines)
```

Per item, a vector divided by a number gives a vector: row level.

One value per file, from its rows:

```julia
@plot mapping(:gap_um, maximum(:data.CurrentHigh_A); color=:Chip) * visual(Scatter)
```

`maximum` of a vector is one number, so this is item level: one point per file.

The TLM resistance, with the project's own function:

```julia
resistance(V, I) = last(hcat(ones(length(I)), I) \ V)   # slope of V against I

@plot mapping(:gap_um, resistance(:data.VoltageHigh_V, :data.CurrentHigh_A); color=:Chip) *
    visual(Scatter)
```

## Example 2: a matrix per item

Selected: two maps, each the current at 201 bias voltages (rows) and 11 gate voltages (columns).
The header lists the voltages, so they are metadata:

```
metadata                          data (a 201 × 11 matrix)
Device   D3                                 gate 1   gate 2  …  gate 11
bias_V   [-1.0, -0.99, …, 1.0]    bias 1    …        …          …
gate_V   [-2.0, -1.6, …, 2.0]     bias 2    …
                                  …
```

One curve per gate voltage, for each map:

```julia
@plot mapping(:bias_V, :data; color=:gate_V', layout=:Device) * visual(Lines)
```

`bias_V` runs down the rows and `gate_V'` along the columns, so each entry gets its bias, its gate
and its item's device: one point per entry.

A heatmap per map. A heatmap is a grid mark, so it takes the matrix and the two voltage lists whole:

```julia
@plot mapping(:bias_V, :gate_V, :data; layout=:Device) * visual(Heatmap)
```

The voltage lists may also be cell edges, one entry longer than the matrix side. Without voltages,
the matrix alone is drawn by position:

```julia
@plot mapping(:data) * visual(Heatmap)
```

The largest current at each gate voltage, one curve per map:

```julia
@plot mapping(:gate_V, vec(maximum(:data; dims=1)); color=:Device) * visual(Lines)
```

`maximum(:data; dims=1)` is ordinary Julia: one value per column, as long as `gate_V`.

## Groups

A selected group is one entry of the selection with its own values and its members one level
down. A chip with its devices:

```
selection                    one entry per chip
├── Chip, Rc, Rsh            the chip's own values (for example a fit over its devices)
└── devices                  its members, each with metadata and data
    ├── gap_um, Device, …
    └── data.VoltageHigh_V, …
```

The same rules apply. `:devices.gap_um` is a vector per chip; `:devices.data.VoltageHigh_V` is one
vector per device. The TLM plot of two chips:

```julia
@plot mapping(:devices.gap_um, :devices.R; color=:Chip) * visual(Scatter)
```

Groups are not selectable this way today; see [groups](groupings.md#selection-and-browsing).

## In code outside plots

`selection` follows the same nesting, and nothing is read until it is used.

```julia
selection.Device                 # one value per item
selection.data                   # a view of the items' data; reads nothing
selection.data.VoltageLow_V      # a view of that column in each item's data
selection.data.Device            # error: Device is not in the data; it is selection.Device
DataFrame(selection.data)        # error: name the values you want
```

A flat table is made only when values are named together, with `unnest`. It repeats the item
values on each row, as `unnest` does in R's tidyr and `flatten` does in DataFrames for a column of
vectors. The name `unnest` is decided; it clashes with no common Julia package.

```julia
unnest(Device = selection.Device, VoltageLow_V = selection.data.VoltageLow_V)
```

Each keyword names a column, and each value has one entry per item. Within an item, the entries
broadcast together, so a formula is an ordinary Julia broadcast over the items:

```julia
unnest(gap_um = selection.gap_um,
    R = resistance.(selection.data.VoltageHigh_V, selection.data.CurrentHigh_A))
```

```
Device     VoltageLow_V
C2_50um    0.0            ┐
C2_50um    8e-05          ┘ rows of file 1
C1_2um     0.0            ] rows of file 2
```

In `@plot`, a column is named after the last part of its path. When two columns would share a name,
such as `:filename` and `:data.filename`, both are named by their whole path.

For marks of single observations, `@plot` builds such a table for each layer from the paths in its
mapping. Only the values a mapping names are read.

## Errors

- A path that an item does not have, such as `:data.VoltageLow_V` for an item whose data is a
  matrix, stops with an error that names the item and the path.
- Values of one item that do not broadcast together, such as a 201-entry vector and a 200-row
  column, stop with Julia's broadcasting error, which names the sizes.

## Open questions

1. How a selected group's members are reached when groups are selectable.
2. Data of a project's own type: its fields as paths (`:data.spectrum`) are the natural reading.
   Whether every type supports this through `getproperty`, or needs a method, is not decided.
3. `id` and `label` stay item-level values. Whether the tree-level `folder` value is metadata or a
   separate kind of value is not decided.

## Relation to the current code

The current [`Selection`](../../lib/DataBrowserCore/src/Workspace/Selection.jl) is the item level
of this model with a `data` column. The proposal removes that column, replaces it with the
`selection.data` view, names tree levels as described, and adds `unnest`. The plot builder and
`@plot` read values through paths.
