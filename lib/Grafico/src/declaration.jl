"""
A plot whose values come from an input given when it is drawn, as `@plot` writes it without
`data(...)`. Draw it with `figure(declaration, input)`.
"""
struct Declaration
    ## The Grafico declaration for an input.
    layers::Function
    ## The type of the values of each named role of each line for an input, as `role => type`,
    ## inferred without drawing; see `scale_kinds`.
    types::Function
end

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
categories, `:categorical`, or numbers, `:continuous`. The types of a declaration's values are
inferred from the types of `input`, without drawing it. A mapping whose type is not known, or that
holds values of both kinds in different lines, is left out.
"""
scale_kinds(_...) = Dict{Symbol,Symbol}()

"""
    scale_categories(lines) -> Dict{Symbol,Vector{Any}}

For each named mapping of the lines of a `@plot` block that divides the points into groups, such as
`:color`, the values it takes in the points, sorted.
"""
scale_categories(_) = Dict{Symbol,Vector{Any}}()

# A line of a `@plot` block: its layers, the named roles that it takes from the header, and whether
# it is drawn, which `@invisible` or a `nothing` or `false` layer turns off.
struct PlotLine
    layers::Any
    shared::Vector{Symbol}
    drawn::Bool
    PlotLine(layers, shared::Vector{Symbol}, drawn::Bool) =
        new(layers, shared, drawn && layers !== nothing && layers !== false)
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
    ## Each role's scale settings, such as `:color => (; categories=["72b", "719a"])`.
    scales::Vector{Pair{Symbol,Any}}
    ## The text of each entry in the section that holds a role: `:color => entry -> text`.
    texts::Vector{Pair{Symbol,Function}}
    ## The legend's settings, such as `merge` and `position`.
    legend::NamedTuple
    theme::Union{Nothing,PlotTheme}
    ## The settings of each `coord(...)` line, in order, such as `(; y = (; scale = log10))`; the
    ## function of the points that a line takes by place is under `points`.
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

# The one group of `result` that the legend entry determines: the group whose values in the entry's
# roles are the entry's values.
function entry_values(result::Result, entry::LegendEntry)::NamedTuple
    matches(group) = all(getfield(result, :named)) do (role, value)
        !haskey(entry.values, role) || category(value, group[column(value)]) == entry.values[role]
    end
    found = filter(matches, getfield(result, :groups))
    length(found) == 1 || error("The legend entry $(describe(entry)) matches $(length(found)) groups of a " *
        "result; its text can read only a value that the entry determines")
    return only(found)
end

"""
    @plot declaration
    @plot header begin
        layer
        ...
    end

A plot declaration of one panel. Without `data(...)`, the names in `mapping` are paths into the
items the plot is drawn for: `:Device` is a metadata value of each item, and `:data.V` is the
column `V` of each item's data.

    @plot mapping(:data.V, :data.I; color=:Device) * visual(Lines)

The positions can also be named: `mapping(; x=:data.V, y=:data.I, color=:Device)` is the same
mapping. A `y` without `x` draws its values against the vertical axis: `mapping(; y=:gap) *
visual(Hist)` is a histogram whose bars grow to the right, unless the `visual` sets `direction`. A
line with only `y` takes the header's `x`.

A mapping can draw several values on the vertical axis: `y2`, `y3` and so on are drawn as well as
`y`, which can also be named `y1`. `ydims()` maps which of them a point shows, and each title after
`=>` names one of them in the legend:

    mapping(; x=:gap, y=:Rp => "V > 0", y2=:Rm => "V < 0", marker=ydims(), linestyle=ydims())

With a header and a block, each line of the block is a layer of the header, and the layers are
drawn in order. A line that evaluates to `nothing` or `false` is left out.

    @plot mapping(:gap, :R; color=:Chip) begin
        visual(Scatter; markersize=6)
        mapping(; marker=:Site) * visual(Scatter)
        mapping(:gap, :R2; color=nothing) * visual(Lines)
    end
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
    ## Each line, named or drawn, is a layer of the header; a name holds its line's value.
    statements = [Expr(:(=), name, declare_layers(:($inherit($header, $value)), input))
        for (name, value) in (statement.args for statement in statements)]
    uses(block, :fit) && pushfirst!(statements, :(fit = $Fit))
    uses(block, :aggregate) && pushfirst!(statements, :(aggregate = $Aggregate))
    ## The settings of x and y in the `scales` lines, which the analyses take.
    axes = [Expr(:kw, key, value) for line in settings if line.args[1] === :scales
        for (key, value) in last(call_arguments(line)) if key === :x || is_y_scale(key)]
    pushfirst!(statements, :($AXES = $(Expr(:tuple, Expr(:parameters, axes...)))))
    ## Each line that is a layer, with the named roles it takes from the header: those its own
    ## mapping does not set.
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
    ## The type of each named role's values in each drawn line, for `scale_kinds`. A line with data of
    ## its own, or that reads a named result, is left out.
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

# The points of a layer with a fit or an aggregate, as code, so that a workspace can compute the
# step again when the items change: the code of the step, such as `fit(line, (a = 1,))`, the code of
# the value of each column, such as `:data.V` for `:V`, and the function that gives the points of a
# collection of items.
struct Points{T<:Function}
    step::String
    texts::Dict{Symbol,String}
    table::T
end
