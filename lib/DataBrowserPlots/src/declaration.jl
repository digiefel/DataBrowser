"""
A plot whose values come from an input given when it is drawn, as `@plot` writes it without
`data(...)`. Draw it with `figure(declaration, input)`.
"""
struct Declaration
    # The AlgebraOfGraphics declaration for an input.
    layers::Function
    # The type of the values of each named role of each line for an input, as `role => type`,
    # inferred without drawing; see `scale_kinds`.
    types::Function
end

# A line of a plot as a layer of the header, `inherit(header, line)`, a layer with its fit done over
# its points, `resolve(layer, items, axes)`, and a line drawn over the groups of a named result,
# `over_result(result, table, line)`. The AlgebraOfGraphics extension defines them.
function inherit end
function resolve end
function over_result end

"""
    mappings(lines) -> Vector{Vector{Symbol}}

For each line of a `@plot` block, drawn or not, the named mappings that its plot types can show,
such as `:color` and `:markersize` for `Scatter`, and those of the layout, such as `:row`. A plot
without a block has no lines.
"""
mappings(_) = Vector{Symbol}[]

"""
    scale_kinds(lines) -> Dict{Symbol,Symbol}
    scale_kinds(declaration, input) -> Dict{Symbol,Symbol}

For each named mapping of the lines of a `@plot` block, such as `:color`, whether its scale holds
categories, `:categorical`, or numbers, `:continuous`, as AlgebraOfGraphics judges the type of its
values. The types of a declaration's values are inferred from the types of `input`, without
drawing it. A mapping whose type is not known, or that holds values of both kinds in different
lines, is left out.
"""
scale_kinds(_...) = Dict{Symbol,Symbol}()

"""
    scale_categories(lines) -> Dict{Symbol,Vector{Any}}

For each named mapping of the lines of a `@plot` block that divides the points into groups, such as
`:color`, the values it takes in the points, sorted.
"""
scale_categories(_) = Dict{Symbol,Vector{Any}}()

# The latest world: code that the browser runs defines the declaration after the caller started.
figure(declaration::Declaration, input, args...; options...) =
    figure(Base.invokelatest(declaration.layers, input), args...; options...)

# A line of a `@plot` block: its layers, the named roles that it takes from the header, and whether
# it is drawn, which `@invisible` turns off.
struct PlotLine
    layers::Any
    shared::Vector{Symbol}
    drawn::Bool
end

# Layers grouped by the y mapping whose scale they use, such as :y or :y3.
struct YScaleLayers
    layers::Vector{Pair{Symbol,Any}}
end

"""
The lines of a `@plot` block, each with layers of its own. A role that a line takes from the
header is left out of the layers that cannot show it, such as `markersize` of a `Lines` layer. Draw
them with `figure(lines)`.
"""
struct PlotLines
    lines::Vector{PlotLine}
end

# The `theme(...)` line of a plot: one of Makie's themes by name, such as `:dark` for `theme_dark` or
# `:default`, or `nothing` for the theme in use, and the settings that change it.
struct PlotTheme
    base::Union{Nothing,Symbol}
    settings::NamedTuple
end

"""
Layers with the plot's own scales, legend texts and theme, as the `scales(...)`, `legend(...)` and
`theme(...)` lines of [`@plot`](@ref) give them. Draw it with `figure(plot)`.
"""
struct Scaled
    layers::Any
    # Each role's scale settings, such as `:color => (; categories=["72b", "719a"])`.
    scales::Vector{Pair{Symbol,Any}}
    # The text of each entry in the section that holds a role: `:color => entry -> text`.
    texts::Vector{Pair{Symbol,Function}}
    # The legend's settings, such as `merge` and `position`.
    legend::NamedTuple
    theme::Union{Nothing,PlotTheme}
    # The settings of each `coord(...)` line, in order, such as `(; y = (; scale = log10))`; the
    # function of the points that a line takes by place is under `points`.
    coords::Vector{NamedTuple}
end

# The roles whose values a legend explains, and whose section a legend text names.
const LEGEND_ROLES = (:color, :marker, :linestyle, :markersize, :linewidth)

"""
One entry of a legend: the values of the roles in its section, as `role => value`, and the name of
each value of each role in its scale, as `role => (value => name)`.
"""
struct LegendEntry
    values::Dict{Symbol,Any}
    names::Dict{Symbol,Dict{Any,String}}
end

describe(entry::LegendEntry) = join(("$role = $value" for (role, value) in entry.values), ", ")

"""
The values of the header that legend texts read: a table with a column for each of the header's
roles and for each path a text reads, and the roles, as `role => value` of the header's mapping
with each value naming its column.
"""
struct LegendRows
    table::NamedTuple
    roles::Vector{Pair{Symbol,Any}}
end

# The value of `name`, a column of the rows, that the entry determines: the one value of the rows
# whose roles have the entry's values. A value of a role shows as its scale names it.
function entry_text(entry::LegendEntry, rows::LegendRows, name::Symbol)::String
    table = rows.table
    shown = [role => value for (role, value) in rows.roles if column(value) === name]
    value_in(row) = isempty(shown) ? table[name][row] : category(last(first(shown)), table[name][row])
    entry_rows = filter(eachindex(table[name])) do row
        all(((role, value),) -> !haskey(entry.values, role) || category(value, table[column(value)][row]) == entry.values[role],
            rows.roles)
    end
    found = unique(value_in.(entry_rows))
    length(found) == 1 || error("The legend entry $(describe(entry)) has $(length(found)) values of $name; " *
        "its text can read only a value that the entry determines")
    value = only(found)
    names = isempty(shown) ? Dict{Any,String}() : get(entry.names, first(first(shown)), Dict{Any,String}())
    return get(names, value, string(value))
end

# The metadata of the one group of `result` that the legend entry determines: the group whose
# values in the entry's roles are the entry's values.
function entry_values(result::Result, entry::LegendEntry)::NamedTuple
    matches(group) = all(getfield(result, :named)) do (role, value)
        !haskey(entry.values, role) || category(value, metadata(group)[column(value)]) == entry.values[role]
    end
    found = filter(matches, getfield(result, :groups))
    length(found) == 1 || error("The legend entry $(describe(entry)) matches $(length(found)) groups of a " *
        "result; its text can read only a value that the entry determines")
    return (; metadata(only(found))...)
end

"""
    @plot declaration
    @plot header begin
        layer
        ...
    end

A plot declaration of one panel, in AlgebraOfGraphics syntax. Without `data(...)`, the names in
`mapping` are paths into the items the plot is drawn for: `:Device` is a metadata value of each
item, and `:data.V` is the column `V` of each item's data.

    @plot mapping(:data.V, :data.I; color=:Device) * visual(Lines)

The positions can also be named: `mapping(; x=:data.V, y=:data.I, color=:Device)` is the same
mapping. A `y` without `x` draws its values against the vertical axis: `mapping(; y=:gap) *
visual(Hist)` is a histogram whose bars grow to the right, unless the `visual` sets `direction`. A
line with only `y` takes the header's `x`.

A mapping can draw several values on the vertical axis: `y2`, `y3` and so on are drawn as well as
`y`, which can also be named `y1`. `ydims()` maps which of them a point shows, and each title after
`=>` names one of them in the legend:

    mapping(; x=:gap, y=:Rp => "V > 0", y2=:Rm => "V < 0", marker=ydims(), linestyle=ydims())

The values of one item in one layer broadcast together, so this draws one point per row of each
item's data, each with its item's device. Each layer reads its own values, so a layer of one point
per item can be drawn next to a layer of the items' rows. A mapping may also be a formula of paths,
computed once for each item:

    @plot mapping(:gap, resistance(:data.V, :data.I)) * visual(Scatter)

Draw it with [`figure`](@ref)`(declaration, selection)`; in the browser's plot builder, the window
draws it for the selected items. Symbols elsewhere in a formula, such as `get(x, :key, 0)`, are
read as paths too.

With a header and a block, each line of the block is a layer of the header, and the layers are
drawn in order.

    @plot mapping(:gap, :R; color=:Chip) begin
        visual(Scatter; markersize=6)
        mapping(; marker=:Site) * visual(Scatter)
        mapping(:gap, :R2; color=nothing) * visual(Lines)
    end

A line takes the header's mapping and changes it with its own: its positions, such as `:gap, :R2`,
replace the header's; its named roles, such as `marker`, add to the header's or replace them; and a
role set to `nothing` is removed. A role of the header that the line's plot type cannot show, such as
`markersize` for `Lines`, is left out of that line, while its values still divide the line's points
into groups and place them in the legend: with `marker` and `linestyle` in one legend section, the
entry for a value shows its marker from `Scatter` and its line style from `Lines`. A role of the line's own mapping that its plot type cannot show is an error. Write a
layer with `*` within a line; a line that continues on the next one ends with `*`.

With `data(table)`, the declaration is ordinary AlgebraOfGraphics over that table, and the names in
`mapping` are its columns. Draw it with `figure(declaration)`.

A layer with its own `data(...)` keeps its own mapping: the header's names belong to other data.
When that data is a [`Selection`](@ref), the names in its `mapping` are paths into its items, as for
the items the plot is drawn for.

`fit` fits a curve to the points of its line and draws it:

    resistance(gap; Rc, Rsh) = 2Rc + Rsh * gap

    @plot mapping(:gap, R(:data.V, :data.I); color=:Chip) begin
        visual(Scatter)
        fit(resistance, (Rc=1.0, Rsh=1.0)) * visual(Lines)
    end

The curve is a function of x with its parameters as keywords, and `fit` takes the curve and a
starting value for each parameter. The line's two positional values are x and y, and its
categorical named roles, here `color=:Chip`, divide the points into groups, with one fit each. The
line changes the points as any line does: `mapping(; color=nothing) * fit(...)` fits all of them
at once.
`fit` gives a [`Result`](@ref): one `Group` for each group of points. Its metadata holds the
group's values, such as `:Chip`, and each parameter, such as `:Rc`, a [`Parameter`](@ref) that
prints as the estimate ± one standard error. Its data is the drawn curve, and its members are the
items whose points it fits. `fit(...; xlim=(0, 25))` draws the curve over that range of x instead
of over the fitted points. With `data(table)` in the header, `fit` takes the rows of that table.
`fit` comes before the visual in its line: the visual draws the result.

The visual draws the fit on the axes of the points and in the roles of its group, so the group's
legend entry shows its points and its curve. Without a visual, a fit is drawn with `Lines`.

When the plot draws items of a workspace, each group of a `fit` or an `aggregate` is an item of the
workspace, under `Computed`, and a fit's parameters are its metadata. The workspace computes a group
again when one of its items changes, or when the code that gives the result changes: the `fit` or
`aggregate` call and the functions it calls, such as the curve, the values mapped to x, y and the
roles that form the groups, and the limits and function of the axes. A change of visuals, palette or legend draws the result again without
computing it. The items stay in the workspace until it closes.

`aggregate` applies functions to the y values of the points that share x and their groups: it
splits the points into one group for each x and each value of the categorical roles, such as
`color`, and applies each function to the y values of each group. A visual draws the values at
each x, in the order of the functions, and a function that gives several values, such as `extrema`,
gives the visual one value for each:

    @plot data(table) * mapping(:x, :y; color=:sample) begin
        visual(Scatter)
        aggregate(mean) * visual(Lines)
        aggregate(mean, std) * visual(Errorbars)
        aggregate(extrema) * visual(Rangebars)
    end

The visual gives each value its meaning: the third value of `Errorbars` is the length of the bar on
each side of y, and the two values of `Rangebars` are the ends of the bar. A visual that does not draw
as many values as the aggregate gives, such as `Lines` with `aggregate(mean, std)`, is an error.

A named aggregate can be drawn by more than one line. Each line maps the values it draws, each
under the name of its function, and a value of a function that gives several is read by index:

    result = aggregate(mean, std, extrema)
    mapping(y = result.mean) * visual(Lines)
    mapping(result.x, result.mean, result.std) * visual(Errorbars)
    mapping(result.x, result.extrema[1], result.extrema[2]) * visual(Rangebars)

A line that maps only `y` takes the x of the groups.

`aggregate` gives a [`Result`](@ref) with one `Group` for each x and group of points, in order of
x, so that `Lines` joins them from left to right. Its metadata holds the x and the roles' values,
the value of each function under its name, such as `:mean`, and the `count` of the points; its
members are the items whose points it takes. Without a visual, an aggregate of one function is drawn
with `Scatter`.

A named result reads the values of its groups by name: `result.count` is the count of each group,
and `contacts.Rc` the parameter `Rc` of each fit. A line that reads them, such as
`mapping(result.x, result.count) * visual(Lines)`, draws one point for each group, in the roles of
the result's points.

The analyses take the values after the function of the y scale, such as `log10`, as
`expectation()` does: on a log axis, `aggregate(mean)` gives the mean of the logarithms, and `fit`
measures how far its curve is from the points in decades. A result holds the values as its functions
give them: with `scale = log10`, `\$(result.mean)` in a legend text is a number of decades, and
`\$(10^result.mean)` is the value in the units of the data. Drawing places them back on the axis by
what the visual draws: a y value as a position, and the third value of `Errorbars` as a length on
each side of y in decades. A value that a line computes itself, such as `10^result.mean`, is drawn as
it is.

A line `name = value` gives a name to the value of the line for the other lines, such as a fit
drawn twice:

    contacts = fit(resistance, (Rc=1.0, Rsh=1.0))
    contacts * visual(Lines)
    contacts * visual(Scatter; markersize=4)

The name holds the fit's result, which has its own data: a line that draws it keeps the
result's mapping.

[`@invisible`](@ref) before a line keeps the line in the plot without drawing it:

    @invisible contacts * visual(Scatter; markersize=4)

## Secondary y axes

Every mapped `yN` has scale settings of the same name. Unspecified settings inherit from `y`.
For example, `y2` uses the same scale as `y` by default; `position=:right` places its scale on
an independent right axis. The scales share x. This currently requires one panel.

    @plot mapping(; x=:data.time, y=:data.voltage, y2=:data.current) begin
        visual(Lines)
        scales(y=(; label="Voltage (V)"), y2=(; position=:right, label="Current (A)"))
    end

The same rule applies to `y3`, `y4` and further defined y mappings.

## Scales and legend

A `scales` line sets the scale of a role: the look of each value, the order of the values and
their names, as AlgebraOfGraphics' `scales` takes them.

    scales(color = (; categories = ["719a" => "Chip 719a", "72b" => "Chip 72b"]))

The scales of `x` and `y` set their axes:

    scales(x = (; label = "Gap (µm)"), y = (; label = "R (Ω)", scale = log10, limits = (1, 1e4)))

- `label` names the axis.
- `scale` is a function, such as `log10`, that applies to the values before the analyses run, so it
  can change their results: the mean of `expectation()` or `aggregate(mean)` is then taken of the
  logarithms.
- `limits` are the lowest and highest value shown. The values outside them are removed before the
  analyses run, so they can change their results too.
- `reversed = true` draws the axis from the highest value to the lowest.

A `coord` line changes only where the values are drawn, after the analyses ran:

    coord(y = (; scale = log10, limits = (1e-9, 1e-5)), aspect = DataAspect())

- `scale` draws the axis with that function, such as `log10`, while the analyses take the values
  as they are: the mean of `expectation()` is then the mean of the values, drawn on a log axis.
- `limits` are the lowest and highest value shown; the values outside them stay in the analyses.
- `reversed = true` draws the axis from the highest value to the lowest.
- `label` names the axis, for when a function of the points changes what it shows.
- A function given by place takes the x and y of each point and gives where it is drawn. Here it
  swaps the axes, and the second line turns a FORC map into coercive and interaction fields:

      coord((x, y) -> (y, x))
      coord((Hr, H) -> ((H - Hr) / 2, (H + Hr) / 2); x = (; label = "Hc"), y = (; label = "Hu"))

  The lines apply in order, and a function comes before the lines that set a `scale` or `reversed`.
  Only the points move: the cells of a `Heatmap` and the bars of a `BarPlot` stay upright.
- `aspect` is Makie's `aspect` of the axis, such as `DataAspect()`, which draws one unit of x as
  long as one unit of y.

The legend has a section for each role, such as `color`. Roles share a section when one of them
determines the others, that is, when each of its values is drawn with the same values of the
others: one entry then shows a chip's color and its site's line style. Each entry is named after
its values, by their names in the scales. A section's title is the `label` of its role's scale; an
empty one, as in `scales(color = (; label = ""))`, leaves the section without a title, and
`legend(titlevisible = false)` leaves every section without one.

A `legend` line sets the text of each entry in the section that holds a role. A path in the text
reads the header's value for the entry, as the header reads it: a metadata value of the entry's
items, or a column of the header's data. A value that a role maps shows by its name in the scale.
A name of the block reads the value of that result for the entry's group:

    legend(color = "\$(:Chip) on \$(:Wafer): Rc = \$(contacts.Rc) Ω")

The text reads only values that the entry determines: `:Wafer` needs each chip to be on one
wafer, and `contacts.Rc` needs the fit's groups to come from roles of the entry's section.

The other settings of a `legend` line are those of [`figure`](@ref)'s legend: `position`, `show`,
`merge`, and those of Makie's `Legend`. `legend(merge = (:color, :linestyle))` puts those roles in
one section, with one entry for each combination of their values that is drawn,
`legend(merge = true)` puts all roles in one, and `legend(merge = false)` gives each role a section
of its own, also when one determines another.

## Theme

A `theme` line sets the look of the plot: one of Makie's themes, such as `:dark` for `theme_dark`
or `:default` for Makie's default theme, changed by Makie's theme settings. Settings for the whole figure come first, then a group for each
of Makie's blocks or plot types:

    theme(:dark; fontsize = 14, Axis = (; xgridvisible = false), Scatter = (; markersize = 10))

Without a name, the settings change the theme in use. The theme is for how the plot looks: the
labels, scales, limits and ticks of the axes belong in `scales`, and settings such as the bins of
`Hist` in `visual`.
"""
macro plot(header, block)
    Meta.isexpr(block, :block) || error("@plot takes a header and a `begin ... end` block of layers")
    header_roles_y = y_roles(header)
    raw_lines = filter(line -> !(line isa LineNumberNode), block.args)
    roles_y = [something(y_roles(line), header_roles_y, [:y]) for line in raw_lines]
    header, block = positions_named(header), positions_named(block)
    lines = filter(line -> !(line isa LineNumberNode), block.args)
    invisible = [Meta.isexpr(line, :macrocall) && line.args[1] === Symbol("@invisible") for line in lines]
    lines = [hidden ? last(line.args) : line for (line, hidden) in zip(lines, invisible)]
    statements = filter(line -> Meta.isexpr(line, :(=)), lines)
    names = Symbol[first(statement.args) for statement in statements]
    settings = filter(line -> Meta.isexpr(line, :call) && line.args[1] in (:scales, :legend, :theme, :coord), lines)
    input = gensym("input")
    # Each line, named or drawn, is a layer of the header; a name holds its line's value.
    statements = [Expr(:(=), name, declare_layers(:($inherit($header, $value)), input))
        for (name, value) in (statement.args for statement in statements)]
    uses(block, :fit) && pushfirst!(statements, :(fit = $Fit))
    uses(block, :aggregate) && pushfirst!(statements, :(aggregate = $Aggregate))
    # The settings of x and y in the `scales` lines, which the analyses take.
    axes = [Expr(:kw, key, value) for line in settings if line.args[1] === :scales
        for (key, value) in last(call_arguments(line)) if key === :x || is_y_scale(key)]
    pushfirst!(statements, :($AXES = $(Expr(:tuple, Expr(:parameters, axes...)))))
    # Each line that is a layer, with the named roles it takes from the header: those its own
    # mapping does not set.
    call = find_call(header, :mapping)
    header_roles = call === nothing ? Symbol[] : first.(last(call_arguments(call)))
    own_roles(line) = (own = find_call(line, :mapping); own === nothing ? Symbol[] : first.(last(call_arguments(own))))
    drawn = map(filter(((line, _, _),) -> !Meta.isexpr(line, :(=)) && !(line in settings), collect(zip(lines, invisible, roles_y)))) do (line, hidden, roles)
        shared = QuoteNode.(setdiff(header_roles, own_roles(line)))
        declared = declare_line(header, line, names, input)
        declared = :(let $AXES = (; $AXES..., yroles=$(QuoteNode(Tuple(roles))))
            $declared
        end)
        :($PlotLine($declared, Symbol[$(shared...)], $(!hidden)))
    end
    declared = isempty(drawn) ? declare_layers(header, input) : :($PlotLines([$(drawn...)]))
    # The type of each named role's values in each drawn line, for `scale_kinds`. A line with data of
    # its own, or that reads a named result, is left out.
    # TODO: the types of the values of a line that reads a named result, such as `result.mean`.
    named = call === nothing ? Pair{Symbol,Any}[] : last(call_arguments(call))
    types = has_data(header) ? Expr[] : [:($(QuoteNode(role)) => $(per_item_type(value, input)))
        for line in lines if !Meta.isexpr(line, :(=)) && !(line in settings) && !has_data(line) && !any(name -> uses(line, name), names)
        for (role, value) in merge(Dict(named), Dict(find_call(line, :mapping) === nothing ? [] : last(call_arguments(find_call(line, :mapping)))))
        if value !== :nothing]
    return esc(declare(declared, statements; input, settings=declare_settings(settings, header, names, input), types))
end

"""
    @invisible line

Keeps a line of a [`@plot`](@ref) block in the plot without drawing it. Remove `@invisible` to draw
the line again.
"""
macro invisible(line)
    error("@invisible marks a line of a @plot block, such as `@invisible visual(Scatter)`")
end

macro plot(declaration)
    input = gensym("input")
    return esc(declare(declare_layers(positions_named(declaration), input), [:($AXES = (;))]; input))
end

is_y_scale(name::Symbol) = name === :y || occursin(r"^y[1-9]\d*$", String(name))

# The name that holds the settings of the plot's x and y scales, as `(; x, y)` of the `scales` line,
# for the analyses: they take the points inside the limits, after the scale's function.
const AXES = Symbol("#axes")

# The points of a layer with a fit or an aggregate, as code, so that the workspace can compute the
# step again when the items change: the code of the step, such as `fit(line, (a = 1,))`, the code of
# the value of each column, such as `:data.V` for `:V`, and the function that gives the points of a
# selection of items.
# The function's type is part of the type of a fit's computed item, so the item is computed again
# when the code of a formula of the points changes.
struct Points{T<:Function}
    step::String
    texts::Dict{Symbol,String}
    table::T
end

