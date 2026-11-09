# Analysis walkthrough: interpolate, gradient, compare

*Archived on 10 November 2026. This is a historical record: the code and the [active plans](../README.md) have moved on, and are right where they differ.*

**Scope correction, Davide, 21 October:** DBRecipes reads common sources and produces processed
items without requiring the type API. Only the source-loading section below belongs to DBRecipes.
The later combination, exploration, plotting and reproducible analysis are shared by all users.
This draft previously put those operations under Recipes incorrectly. Its result/register_result!
forms and proposed replacement by a DBRecipes macro are withdrawn as general analysis APIs.
The external agent is rewriting the example; this filename is retained during coordination.

The source-loading section describes today's API. Later sections are superseded proposal material,
not an approved or implemented analysis API. [Processing](../processing.md#analysis-after-item-processing)
owns the corrected scope. The coordination note `work/doc-curation.md` gave the next example
request; it left the repository in commit `99e6737`, and `git show 00f1e65:work/doc-curation.md`
prints it.

## The data

A directory of single-point measurements on a wafer. Each CSV file holds one point: its position
`x`, `y` in mm and a sheet resistance `R`.

```julia
using DataBrowser, Statistics

project = define_project("wafer map")
register_csv!(project, :point;
    analyze = (df, _) -> (x = df.x[1], y = df.y[1], R = mean(df.R)))
```

This part is today's API. Every point has the queryable metadata `x`, `y`, `R`.

## The ordinary helpers

Plain Julia, written and tested without DataBrowser:

```julia
# Inverse-distance weighting: each grid value is a weighted mean of the measured values
function interpolate_grid(x, y, v; step = 1.0)
    xs = minimum(x):step:maximum(x)
    ys = minimum(y):step:maximum(y)
    weights(xi, yi) = 1 ./ (hypot.(x .- xi, y .- yi) .^ 2 .+ 1e-12)
    z = [sum(weights(xi, yi) .* v) / sum(weights(xi, yi)) for xi in xs, yi in ys]
    return (; xs, ys, z)
end

gradient_grid(g) = (; dzdx = diff(g.z; dims = 1) ./ step(g.xs),
                      dzdy = diff(g.z; dims = 2) ./ step(g.ys))

# The measured value minus the grid value nearest to the point
function residual(x, y, R, g)
    i = argmin(abs.(g.xs .- x))
    j = argmin(abs.(g.ys .- y))
    return R - g.z[i, j]
end
```

## 1. Try it on the selection, untracked

In the REPL, with the browser open on the workspace `ws`:

```julia
s = selection(ws)                      # a table: one row per selected point
grid = interpolate_grid(s.x, s.y, s.R)
```

This works today: `selection` returns a table whose columns include the metadata. `grid` is an
ordinary named tuple. Nothing is stored, nothing appears in the browser. This is
plain Julia: temporary values do not have to become workspace results.

## 2. Make it a result

One Recipes function turns a call into a tracked result (**OPEN**: name and exact signature):

```julia
result(f, workspace::Workspace, key::AbstractString, inputs...) -> AbstractGroup
```

- `f(inputs...)` is called with the inputs as given. An input can be an item, a group, a
  selection table or one row of it. It returns its data, or
  `(data = ..., metadata = ...)` to add queryable metadata. That second form exists in Recipes
  today for `read` callbacks.
- The returned value is a group. Its members are the tracked inputs: each `AbstractDataItem`
  argument, the items of a selection argument, and the item of a row. Its data is what `f` returned.
- Its id is the current analysis plus `key`. Recipes gives it, as any project gives ids to its
  values; see [groups-toy.md](groups-toy.md#stable-ids). The same `key` in the same analysis is a later
  version of the same result.
- It appears in the current analysis's results, expandable to its inputs (Davide's placement
  decision). It is stored and indexed like any item, and recomputed when an input changes.

The three calls:

```julia
s = selection(ws)

grid = result(ws, "grid", s) do s
    g = interpolate_grid(s.x, s.y, s.R)
    (data = g, metadata = (; zmin = minimum(g.z), zmax = maximum(g.z)))
end

gradient = result(ws, "gradient", grid) do g
    gradient_grid(data(g))
end

p = s[1]                               # one row of the selection: one point
comparison = result(ws, "residual " * p.id, p, grid) do p, g
    (data = nothing, metadata = (; residual = residual(p.x, p.y, p.R, data(g))))
end
```

What the browser shows in the current analysis:

```
grid                    zmin 12.1  zmax 15.8        members: the selected points
gradient                                            members: grid
residual point_07.csv   residual 0.34               members: point_07.csv, grid
```

- `gradient` contains `grid`, not the points: nothing is flattened. The points are reached
  through `grid`.
- The residual has two inputs and keeps both.
- Another client gets the same values: by id from code, or by querying metadata, for example
  `query_items(ws, "residual > 0.3")`.
- Editing `point_07.csv` recomputes `grid`, then `gradient` and the residual. Changing the
  selection does not: the results keep the points they were made from. A new selection is a new
  call.

## 3. Repeat it for every wafer

When the analysis works, it becomes part of the project. Groups come from the source or from the
`collection` callback; here each wafer is a group. One registration runs the same code on every
group of a kind (**OPEN**: name and keywords):

```julia
register_result!(project, "grid"; on = :wafer) do s
    g = interpolate_grid(s.x, s.y, s.R)
    (data = g, metadata = (; zmin = minimum(g.z), zmax = maximum(g.z)))
end
```

- Core calls it once per wafer group, with that group's members as a table like `selection`. The result's id is `"grid"`
  plus the wafer's id.
- The `do` block is the same as in section 2. Moving from a trial to the project changes the call
  around it, not the code inside.
- The gradient and the residuals register the same way, on the `"grid"` results and on each
  point with its wafer's grid. Their exact keywords are left open until this shape is reviewed.

## Two ways to give metadata

The residual is only a number, and its role is metadata. Two forms can say so:

| | Returned value | Separate callback |
|---|---|---|
| The author writes | `(data = nothing, metadata = (; residual = r))` | `result(ws, key, p, grid; summarize = r -> (; residual = r)) do … end` |
| Callbacks per result | one | two |
| A helper that returns only data | wrap it, or add `summarize` | add `summarize` |
| Today's Recipes | the `(data = …, metadata = …)` form of `read` | the `analyze` callback |

A named tuple alone cannot say whether it is data or metadata, so one of the two forms is needed.
The returned-value form keeps one callback and matches `read`; the separate callback keeps helpers
unwrapped. Both can exist.

## What changes in Recipes today

- `register_collection!` requires its `process` to return new data for each item below the
  collection, and its `analyze` gives metadata to each of those items. `result` and
  `register_result!` remove both limits: a result is a new value with its own id, members and data.
- `RegisteredDataItem`, the private carrier, stays private. A result needs a second private
  carrier, a group with data and metadata; the author never sees either.
- Ids: today `callbacks.jl` builds item ids from the source item, the registration kind and a key.
  Results need the analysis scope plus `key`; this depends on the stable-id design.
- `analyze` on items is unchanged here. Whether it stays is the separate question in
  [processing.md](../processing.md#metadata-comes-from-returned-values).
