# Data model: reaching the values of selected items

[Architecture](../ARCHITECTURE.md) describes `Selection`, paths into item data, and `unnest` as built
today, and the [vision](../vision.md) sets the settled direction. How scripts and plots access the
members of a selected group, and whether group levels become metadata, remain open.

## Levels of groups as metadata

The browser tree shows groups such as the folders of a `DirectorySource` or the hierarchy levels of
a `DataBrowserRecipes` project. Today a selection lists those groups only by id in its `groups`
column; under one proposal, their levels appear as metadata too — one `folder` value holding the
relative path (such as `"72b/L/bigTLM"`) plus the level names defined by a recipe (such as `wafer`
and `device`).

## The rules

1. **A formula runs once per item.** Inside a formula, a path evaluates to that item's own value:
   `:Device` is a string, `:data.VoltageLow_V` is a vector, and `:data` is a matrix. Formulas are
   ordinary Julia expressions.
2. **Items are independent.** Each item's mapped values evaluate for that item alone before all
   items' marks are drawn together. Selected items may hold different data shapes, provided every
   item defines the paths named by that mapping.
3. **The mark determines how values combine.**
   - Marks of single observations (points, lines, bars): values broadcast per item as in ordinary
     Julia, yielding one entry per point (`color=:Device` alongside a data column repeats the
     item's device on each row, whereas mapping only per-item scalars yields one point per item). A
     vector runs down a matrix's rows, while a transposed vector (`:gate_V'`) runs along its
     columns; `axes(:data, 1)` gives row indices and `axes(:data, 2)'` gives column indices, even
     for square matrices where axis lengths match.
   - Grid marks (heatmap, image, contour, surface): the matrix and its axes are taken whole, in any
     form Makie accepts (such as cell centers or cell edges).

   Marks belong to the [graphics grammar](graphics-grammar.md); this plan only fixes how values
   reach them per item.

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

Today a selection keeps a group as a single item without its members nested beneath it;
[groups](groupings.md#selecting-a-group-or-its-members) covers how scripts select a group's
members.

## Columns in `@plot`

`unnest` builds a flat table that repeats single-item values on each row of that item's data. In
`@plot`, each column takes the last segment of its path unless two paths collide (such as
`:filename` and `:data.filename`), in which case both keep their full path. For single-observation
marks, `@plot` builds one such table per layer from the paths named in its mapping, reading only
those values.

## Errors

- A path missing on an item (such as `:data.VoltageLow_V` on a matrix-valued item) fails with an
  error naming both the item and the path.
- Values on one item whose dimensions do not broadcast together (such as a 201-entry vector and a
  200-row column) fail with Julia's broadcasting error naming their sizes.

## Open questions

1. How scripts and plots access the members of a selected group.
2. Whether group levels such as `folder` belong in metadata or in a separate kind of value alongside
   `id` and `label`.
