# Grafico.jl

`Grafico` builds plots on top of `Makie` and `Makie.SpecApi`. You describe what to draw with *layers*, pieces of a plot that pair data, column mappings, analyses, and Makie plot types, and `figure` turns your description into a `Makie.Figure`.

## Layers and non-macro syntax

A layer starts with `data(rows)`, where `rows` is any table or vector of named tuples, and `mapping(x, y; ...)`, which names the columns that drive positions and visual roles such as `color`, `marker`, or `linestyle`. Multiplying by `visual(PlotType)` chooses a Makie plot type:

```julia
using Grafico, GLMakie

rows = [
    (V = v, I = chip == "A" ? 0.5v^2 : 0.8v^2, Chip = chip, Site = site)
    for chip in ("A", "B") for site in ("S1", "S2") for v in 0.0:0.5:3.0
]

plt = data(rows) * mapping(:V => "Voltage (V)", :I => "Current (mA)"; color = :Chip) *
      (visual(Scatter; markersize = 8) + visual(Lines))

figure(plt)
```

Adding two layers with `+` draws both on the same axes. You can also add *settings*, plot-wide rules for scales, coordinates, the legend, and the theme, directly with `+` or `*`:

```julia
styled = plt +
    scales(color = (; palette = [:crimson, :royalblue])) +
    coord(y = (; scale = log10, limits = (0.1, 10.0))) +
    legend(merge = true, position = :bottom) +
    plot_theme(:light; Axis = (; xgridvisible = false))

figure(styled)
```

When several layers share a common `data` and `mapping` header, you can call the header as a function and pass each layer or setting as an argument:

```julia
header = data(rows) * mapping(:V, :I; color = :Chip)

figure(header(
    visual(Scatter; markersize = 8),
    mapping(; linestyle = :Site) * visual(Lines),
    coord(x = (; label = "Voltage (V)"), y = (; label = "Current (mA)")),
    legend(merge = true),
))
```

A layer that cannot show one of the header's roles leaves that role out automatically; for example, `visual(Lines)` ignores `markersize` when the header maps `markersize`.

### Automatic Makie aesthetics

`Grafico` inspects `Makie.attribute_names(PlotType)` to find which visual roles a Makie plot type accepts, such as `color`, `strokecolor`, `marker`, `markersize`, `linestyle`, `linewidth`, `dodge`, `stack`, and `side`. Call `show_aesthetics(PlotType)` in the REPL to see the positional and keyword mappings for any Makie plot type:

```julia
show_aesthetics(LineSegments)
show_aesthetics(Violin)
```

## The `@plot` macro and item paths

`@plot` writes a multi-layer plot block where each line inherits the header's data and mappings. Prefixing a line with `@invisible` keeps the line in the declaration without drawing it:

```julia
iv_plot = @plot data(rows) * mapping(:V, :I; color = :Chip) begin
    visual(Scatter; markersize = 8)
    mapping(; linestyle = :Site) * visual(Lines)
    @invisible mapping(:V, :V) * visual(Lines; color = :gray)
    legend(color = "Chip $(:Chip)", merge = true)
end

figure(iv_plot)
```

When you omit `data(...)`, `@plot` produces a *declaration*, a plot template that takes its input collection when you call `figure(declaration, items)`. Inside `mapping`, a dotted symbol such as `:data.V` reads the field `V` of `:data` from each item, while a plain symbol such as `:device` reads a per-item value and repeats it across the points of `:data.V`:

```julia
items = (
    device = ["D1", "D2"],
    data = (
        V = [[0.0, 1.0, 2.0], [0.0, 1.0, 2.0]],
        I = [[0.0, 1.1, 3.9], [0.0, 0.6, 2.5]],
    ),
)

curves = @plot mapping(:data.V => "V", :data.I => "I"; color = :device) begin
    visual(Scatter)
    visual(Lines)
end

figure(curves, items)
```

An expression such as `maximum(:data.I)` computes one summary number for each item:

```julia
peaks = @plot mapping(:device, maximum(:data.I) => "Peak current") * visual(BarPlot)
figure(peaks, items)
```

### Multiple vertical series and secondary axes

A mapping can place several series on the vertical axis with `y`, `y2`, `y3`, and so on. `ydims()` maps the series identity to a visual role such as `color`, `marker`, or `linestyle`:

```julia
dual = @plot data(rows) * mapping(; x = :V, y = :I => "Forward", y2 = (:I => x -> 0.5x) => "Reverse", color = ydims()) begin
    visual(Lines)
end

figure(dual)
```

Giving `y2` its own entry in `scales` or `coord` draws `y2` against a right-hand vertical axis with its own scale and label:

```julia
dual_axis = @plot data(rows) * mapping(; x = :V, y = :I, y2 = :I => x -> 100x) begin
    visual(Lines)
    coord(y = (; label = "I (mA)"), y2 = (; scale = log10, label = "100 × I (log)"))
end

figure(dual_axis)
```

## Curve fitting and aggregation

Inside `@plot`, `fit(model, start)` fits `model(x, params...)` to the points of each group by nonlinear least squares (`LevenbergMarquardt`) and draws the fitted curve. Assigning the fit line to a variable lets later lines read the fitted parameters, each of which is a `Measurement` with a value and standard uncertainty (`±`):

```julia
using Statistics: mean, std
using Measurements: value, uncertainty

quadratic(x, a, b) = a * x^2 + b

fitted = @plot data(rows) * mapping(:V, :I; color = :Chip) begin
    visual(Scatter)
    f = fit(quadratic, (a = 0.5, b = 0.0)) * visual(Lines)
    legend(color = "$(:Chip): a = $(round(value(f.a); digits = 2)) ± $(round(uncertainty(f.a); digits = 2))")
end

figure(fitted)
```

Similarly, `aggregate(mean, std)` groups points that share `x` and categorical roles, applies each function to the `y` values, and exposes the results by function name:

```julia
summary_plot = @plot data(rows) * mapping(:V, :I; color = :Chip) begin
    ag = aggregate(mean, std)
    ag * mapping(; y = :mean) * visual(ScatterLines)
    ag * mapping(; y = :mean, delta = :std) * visual(Errorbars)
end

figure(summary_plot)
```

The limits and scale in `scales(x = ..., y = ...)` filter points and transform `y` before `fit`, `aggregate`, `linear()`, `smooth()`, `density()`, `histogram()`, or `expectation()` run. By contrast, `coord(x = ..., y = ...)` changes only how the axes display the finished plot.

## Graphic marks

For custom diagrams, annotations, and data-driven glyphs, `Grafico` provides *graphic marks*, geometric primitives that combine with 2D transforms and styles using `*` and `+` (inspired by `Vizagrams.jl`):

- Primitives: `CircleMark(; r, x, y)`, `RectMark(; w, h, x, y)`, `PolygonMark(points)`, `LineMark(points)`, `Segment(p1, p2)`, `TextMark(text; x, y)`, `SectorMark(r, θ1, θ2; r_inner)` (or `Wedge`), and `RibbonMark(points, widths)`
- Composite diagrams: `histogram_diagram(values; bins, scale_h, baseline, ticks, labels)` and `rose_diagram(categories, values; colors)`
- Transforms: `T(dx, dy)` (translation), `U(sx, sy)` or `U(s)` (scaling), and `R(θ)` (counterclockwise rotation in radians)
- Styling: `Style(; color, strokecolor, strokewidth, linestyle, linewidth, alpha)`

Multiplying a transform or `Style` on the left applies it to every primitive in a mark tree, and `+` superimposes marks:

```julia
badge = T(1.5, 2.0) * (
    Style(color = (:crimson, 0.25), strokecolor = :crimson, strokewidth = 2) * CircleMark(r = 0.35) +
    R(π / 4) * U(0.4) * Style(color = :royalblue) * RectMark(w = 1.0, h = 0.3) +
    T(0.0, 0.55) * Style(color = :black) * TextMark("target"; fontsize = 14)
)

figure(badge)
```

Because composite diagrams are marks, you can rotate and translate them to build tilted statistical plots, such as a marginal histogram aligned along an eigenvector:

```julia
scatter_layer = data(rows) * mapping(:V, :I) * visual(Scatter)
tilted_hist = T(1.5, 2.0) * R(deg2rad(37.0)) * histogram_diagram(rows.I; bins = 5, labels = true, color = (:steelblue, 0.6))

figure(scatter_layer + tilted_hist)
```

Similarly, `rose_diagram` builds circular coxcomb diagrams for Nightingale or polar rose charts:

```julia
topics = ["Safety", "Income", "Jobs", "Health", "Education"]
scores = [6.5, 7.2, 5.8, 8.1, 7.0]
rose = rose_diagram(topics, scores; colors = [:red, :orange, :green, :blue, :purple])

figure(rose)
```

You can also add a mark directly onto any plot with `plt + badge`, or map a function `(x, y, ...) -> mark` over the rows of a layer with `mark(f)`:

```julia
glyphs = data(rows) * mapping(:V, :I; color = :Chip) *
    mark((v, i) -> T(v, i) * (CircleMark(r = 0.08) + Segment((-0.12, 0.0), (0.12, 0.0))))

figure(glyphs)
```

## Composing multi-panel figures

Any two plots (or graphic marks) combine side by side with `a | b` (`hcat`), top to bottom with `a / b` (`vcat`), or in a grid with `[a b; c d]`:

```julia
left_panel  = data(rows) * mapping(:V, :I; color = :Chip) * visual(Scatter)
right_panel = data(rows) * mapping(:V, :I; color = :Chip) * visual(Lines)
bottom_bar  = data(rows) * mapping(:Chip, :I; color = :Chip) * expectation() * visual(BarPlot)

dashboard = (left_panel | right_panel) / bottom_bar
figure(dashboard)
```

## Reactive figures with `Observable`s and `@manipulate`

Every plot in `Grafico` compiles to a declarative `Makie.SpecApi.GridLayout` through `spec(plot)` (or `spec(declaration, input)`). When you pass a `Makie.Observable` to `figure`, Makie diff-updates the existing axes and plots in place whenever the observable changes:

```julia
live_rows = Observable(rows[1:6])
live_plot = data(rows) * mapping(:V, :I; color = :Chip) * visual(ScatterLines)

# Or with a declaration:
decl = @plot mapping(:V, :I; color = :Chip) * visual(ScatterLines)
fig = figure(decl, live_rows)

# Updating the observable updates `fig` in place:
live_rows[] = rows
```

For quick interactive exploration, `@manipulate` builds a `Makie.Figure` with sliders for numeric ranges, toggles for booleans, and drop-down menus for other collections, and updates the plot in place as you move the controls:

```julia
@manipulate for power in 1.0:0.1:3.0, show_scatter in (true, false), palette in [:viridis, :plasma]
    curve_rows = [(x = x, y = c * x^power, group = c) for c in (1.0, 2.0, 3.0) for x in 0.0:0.2:3.0]
    base = data(curve_rows) * mapping(:x, :y; color = :group) * visual(Lines) +
           scales(color = (; colormap = palette))
    show_scatter ? base + data(curve_rows) * mapping(:x, :y; color = :group) * visual(Scatter) : base
end
```
