"""
A plot whose values come from an input given when it is drawn, as `@plot` writes it without
`data(...)`. Draw it with `figure(declaration, input)`.
"""
struct Declaration
    # The AlgebraOfGraphics declaration for an input.
    layers::Function
end

# A line of a plot as a layer of the header, `inherit(header, line)`, and a layer with its fit done
# over its points, `resolve(layer, items)`. The AlgebraOfGraphics extension defines them.
function inherit end
function resolve end

"""
    mappings(lines) -> Vector{Vector{Symbol}}

For each line of a `@plot` block, drawn or not, the named mappings that its plot types can show,
such as `:color` and `:markersize` for `Scatter`, and those of the layout, such as `:row`. A plot
without a block has no lines.
"""
mappings(_) = Vector{Symbol}[]

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

"""
The lines of a `@plot` block, each with layers of its own. A role that a line takes from the
header is left out of the layers that cannot show it, such as `markersize` of a `Lines` layer. Draw
them with `figure(lines)`.
"""
struct PlotLines
    lines::Vector{PlotLine}
end

"""
Layers with the plot's own scales and legend texts, as the `scales(...)` and `legend(...)` lines
of [`@plot`](@ref) give them. Draw it with `figure(plot)`.
"""
struct Scaled
    layers::Any
    # Each role's scale settings, such as `:color => (; categories=["72b", "719a"])`.
    scales::Vector{Pair{Symbol,Any}}
    # The text of each entry in the section that holds a role: `:color => entry -> text`.
    texts::Vector{Pair{Symbol,Function}}
    # The legend's settings, such as `merge` and `position`.
    legend::NamedTuple
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

# The metadata of the one group of `statistic` that the legend entry determines: the group whose
# values in the entry's roles are the entry's values.
function entry_values(statistic::Statistic, entry::LegendEntry)::NamedTuple
    matches(group) = all(statistic.named) do (role, value)
        !haskey(entry.values, role) || category(value, metadata(group)[column(value)]) == entry.values[role]
    end
    found = filter(matches, statistic.groups)
    length(found) == 1 || error("The legend entry $(describe(entry)) matches $(length(found)) groups of a " *
        "statistic; its text can read only a value that the entry determines")
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
into groups. A role of the line's own mapping that its plot type cannot show is an error. Write a
layer with `*` within a line; a line that continues on the next one ends with `*`.

With `data(table)`, the declaration is ordinary AlgebraOfGraphics over that table, and the names in
`mapping` are its columns. Draw it with `figure(declaration)`.

A layer with its own `data(...)` keeps its own mapping: the header's names belong to other data.
When that data is a vector of items, the names in its `mapping` are paths into those items, as for
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
`fit` gives a [`Statistic`](@ref): one `Group` for each group of points. Its metadata holds the
group's values, such as `:Chip`, and each parameter, such as `:Rc`, a [`Parameter`](@ref) that
prints as the estimate ± one standard error. Its data is the drawn curve, and its members are the
items whose points it fits. `fit(...; xlim=(0, 25))` draws the curve over that range of x instead
of over the fitted points. With `data(table)` in the header, `fit` takes the rows of that table.
`fit` comes before the visual in its line: the visual draws the result.

The visual draws the fit on the axes of the points and in the roles of its group, so the group's
legend entry shows its points and its curve. Without a visual, a fit is drawn with `Lines`.

A line `name = value` gives a name to the value of the line for the other lines, such as a fit
drawn twice:

    contacts = fit(resistance, (Rc=1.0, Rsh=1.0))
    contacts * visual(Lines)
    contacts * visual(Scatter; markersize=4)

The name holds the fit's result, which has its own data: a line that draws it keeps the
result's mapping.

[`@invisible`](@ref) before a line keeps the line in the plot without drawing it:

    @invisible contacts * visual(Scatter; markersize=4)

## Scales and legend

A `scales` line sets the scale of a role: the look of each value, the order of the values and
their names, as AlgebraOfGraphics' `scales` takes them.

    scales(color = (; categories = ["719a" => "Chip 719a", "72b" => "Chip 72b"]))

The scales of `x` and `y` set their axes:

    scales(x = (; label = "Gap (µm)"), y = (; label = "R (Ω)", scale = log10, limits = (1, 1e4)))

- `label` names the axis.
- `scale` is a function, such as `log10`, that applies to the values before the analyses run, so it
  can change their results: the mean of `expectation()` is then taken of the logarithms.
- `limits` are the lowest and highest value shown. The values outside them are removed before the
  analyses run, so they can change their results too.
- `reversed = true` draws the axis from the highest value to the lowest.

The legend has a section for each role, such as `color`. Roles share a section when one of them
determines the others, that is, when each of its values is drawn with the same values of the
others: one entry then shows a chip's color and its site's line style. Each entry is named after
its values, by their names in the scales.

A `legend` line sets the text of each entry in the section that holds a role. A path in the text
reads the header's value for the entry, as the header reads it: a metadata value of the entry's
items, or a column of the header's data. A value that a role maps shows by its name in the scale.
A name of the block reads the value of that statistic for the entry's group:

    legend(color = "\$(:Chip) on \$(:Wafer): Rc = \$(contacts.Rc) Ω")

The text reads only values that the entry determines: `:Wafer` needs each chip to be on one
wafer, and `contacts.Rc` needs the fit's groups to come from roles of the entry's section.

The other settings of a `legend` line are those of [`figure`](@ref)'s legend: `position`, `show`,
`merge`, and those of Makie's `Legend`. `legend(merge = (:color, :linestyle))` puts those roles in
one section, with one entry for each combination of their values that is drawn, and
`legend(merge = true)` puts all roles in one.
"""
macro plot(header, block)
    Meta.isexpr(block, :block) || error("@plot takes a header and a `begin ... end` block of layers")
    header, block = positions_named(header), positions_named(block)
    lines = filter(line -> !(line isa LineNumberNode), block.args)
    invisible = [Meta.isexpr(line, :macrocall) && line.args[1] === Symbol("@invisible") for line in lines]
    lines = [hidden ? last(line.args) : line for (line, hidden) in zip(lines, invisible)]
    statements = filter(line -> Meta.isexpr(line, :(=)), lines)
    names = Symbol[first(statement.args) for statement in statements]
    settings = filter(line -> Meta.isexpr(line, :call) && line.args[1] in (:scales, :legend), lines)
    input = gensym("input")
    # Each line, named or drawn, is a layer of the header; a name holds its line's value.
    statements = [Expr(:(=), name, declare_layers(:($inherit($header, $value)), input))
        for (name, value) in (statement.args for statement in statements)]
    uses(block, :fit) && pushfirst!(statements, :(fit = $Fit))
    # Each line that is a layer, with the named roles it takes from the header: those its own
    # mapping does not set.
    call = find_call(header, :mapping)
    header_roles = call === nothing ? Symbol[] : first.(last(call_arguments(call)))
    own_roles(line) = (own = find_call(line, :mapping); own === nothing ? Symbol[] : first.(last(call_arguments(own))))
    drawn = map(filter(((line, _),) -> !Meta.isexpr(line, :(=)) && !(line in settings), collect(zip(lines, invisible)))) do (line, hidden)
        shared = QuoteNode.(setdiff(header_roles, own_roles(line)))
        :($PlotLine($(declare_layers(:($inherit($header, $line)), input)), Symbol[$(shared...)], $(!hidden)))
    end
    declared = isempty(drawn) ? declare_layers(header, input) : :($PlotLines([$(drawn...)]))
    return esc(declare(declared, statements; input, settings=declare_settings(settings, header, names, input)))
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
    return esc(declare(declare_layers(positions_named(declaration), input); input))
end

# The path a value names, such as `[:data, :V]` for `:data.V`, or `nothing`.
function path(expression)::Union{Nothing,Vector{Symbol}}
    expression isa QuoteNode && expression.value isa Symbol && return [expression.value]
    if Meta.isexpr(expression, :., 2) && expression.args[2] isa QuoteNode
        inner = path(expression.args[1])
        inner === nothing || return [inner; expression.args[2].value]
    end
    return nothing
end

# The paths in an expression, outermost first. The field of `x.name` is a name, not a path.
paths(expression)::Vector{Vector{Symbol}} = path(expression) !== nothing ? [path(expression)] :
    Meta.isexpr(expression, :., 2) && expression.args[2] isa QuoteNode ? paths(expression.args[1]) :
    expression isa Expr ? unique(reduce(vcat, map(paths, expression.args); init=Vector{Symbol}[])) : Vector{Symbol}[]

has_data(expression) = Meta.isexpr(expression, :call) && expression.args[1] === :data ||
    expression isa Expr && any(has_data, expression.args)

# The value as written, such as `:data.V` or `resistance(:data.V, :data.I)`.
source_text(value) = string(value)

# Replace each value a `mapping` names that holds a path, or that `chosen` accepts, with
# `f(value)`. A label or a transformation after `=>` stays.
function map_mapped(f, expression; chosen=value -> !isempty(paths(value)))
    expression isa Expr || return expression
    if Meta.isexpr(expression, :call) && expression.args[1] === :mapping
        mapped(value) = Meta.isexpr(value, :call) && value.args[1] === :(=>) ?
            Expr(:call, :(=>), mapped(value.args[2]), value.args[3:end]...) :
            chosen(value) ? f(value) : value
        argument(a) = Meta.isexpr(a, :kw) ? Expr(:kw, a.args[1], mapped(a.args[2])) :
            Meta.isexpr(a, :parameters) ? Expr(:parameters, map(argument, a.args)...) : mapped(a)
        return Expr(:call, :mapping, map(argument, expression.args[2:end])...)
    end
    return Expr(expression.head, map(e -> map_mapped(f, e; chosen), expression.args)...)
end

# The values of a mapped value for each item of `input`. A formula runs once per item, with each
# path replaced by that item's value.
function per_item(value, input::Symbol)
    reading(names) = foldl((e, name) -> Expr(:., e, QuoteNode(name)), names; init=input)
    path(value) === nothing || return reading(path(value))
    found = paths(value)
    arguments = [gensym(join(names, '_')) for names in found]
    replaced(e) = path(e) in found ? arguments[findfirst(==(path(e)), found)] :
        e isa Expr ? Expr(e.head, map(replaced, e.args)...) : e
    return :(map(($(arguments...),) -> $(replaced(value)), $(map(reading, found)...)))
end

# The layers of a declaration, each a product without `+`: `h * (a + b)` is `h * a` and `h * b`, as
# AlgebraOfGraphics multiplies it out.
function layers(expression)
    Meta.isexpr(expression, :call) || return [expression]
    operator, arguments = expression.args[1], expression.args[2:end]
    operator === :+ && return reduce(vcat, map(layers, arguments))
    operator === :* || return [expression]
    return foldl((left, factor) -> [:($a * $b) for a in left for b in layers(factor)], arguments[2:end];
        init=layers(arguments[1]))
end

# The table of the values that the `mapping` of `layer` names, and the layer with each value
# replaced by the name of its column, or `nothing` if no value is chosen. `column(value)` is the
# value's entries, one for each item.
function tabulate(layer, column; chosen=value -> !isempty(paths(value)))
    values = Dict{String,Any}()
    order = String[]
    map_mapped(layer; chosen) do value
        text = source_text(value)
        haskey(values, text) || (values[text] = value; push!(order, text))
        return value
    end
    isempty(order) && return nothing
    # A path's column is named after its last part, unless another column has that name too.
    short(t) = path(values[t]) === nothing ? t : String(last(path(values[t])))
    names = Dict(t => Symbol(count(==(short(t)), map(short, order)) == 1 ? short(t) : lstrip(t, ':'))
        for t in order)
    columns = [Expr(:kw, names[t], column(values[t])) for t in order]
    rewritten = map_mapped(value -> QuoteNode(names[source_text(value)]), layer; chosen)
    return Expr(:call, Workspace.unnest, Expr(:parameters, columns...)), rewritten
end

# One layer as a function of the input: each value its `mapping` names becomes a column of `unnest`
# over the input, and the mapping names that column. With `data(value)`, the paths read `value`
# when it is a vector of items, and the layer is left as it is for any other value. A fit in the
# layer is done over its points (`resolve`), which know their items by the `ITEM` column.
function declare_layer(layer, input::Symbol)
    with_items(table, items) = Expr(table.head, table.args[1], Expr(:parameters, table.args[2].args..., :($item_ids($items)...)))
    own = find_call(layer, :data)
    if own === nothing
        tabulated = tabulate(layer, value -> per_item(value, input))
        tabulated === nothing && return :($resolve($layer, nothing))
        table, rewritten = tabulated
        return :($resolve(data($(with_items(table, input))) * $rewritten, $input))
    end
    value, items = gensym("data"), gensym("items")
    tabulated = tabulate(layer, v -> per_item(v, items))
    tabulated === nothing && return :($resolve($layer, nothing))
    plain = replace_call(layer, own, :(data($value)))
    table, rewritten = tabulated
    of_items = replace_call(rewritten, find_call(rewritten, :data), :(data($(with_items(table, items)))))
    return :(let $value = $(own.args[2])
        $value isa AbstractVector{<:$AbstractDataItem} ?
            (let $items = $(Workspace.select)($value); $resolve($of_items, $items) end) :
            $resolve($plain, nothing)
    end)
end

# The declared layers of `expression`, added.
declare_layers(expression, input::Symbol) =
    foldl((a, b) -> :($a + $b), map(layer -> declare_layer(layer, input), layers(expression)))

# The declared layers, `drawn`, after the `statements`, which define names for them. The result is
# a function of the input when a layer or a statement reads it. `settings` are the statements and
# the arguments of `Scaled` that the scales and legend lines give, or `nothing`.
function declare(drawn, statements=Expr[]; input::Symbol, settings=nothing)
    if settings !== nothing
        statements = [statements; settings.statements]
        drawn = :($Scaled($drawn, $(settings.arguments...)))
    end
    body = isempty(statements) ? drawn : Expr(:let, Expr(:block), Expr(:block, statements..., drawn))
    return uses(body, input) ? :($Declaration($input -> $body)) : body
end

# The `scales(...)` and `legend(...)` lines as the arguments of `Scaled` after its layers, and the
# statements they need, or `nothing` if there are none. A legend text becomes a function of a
# `LegendEntry`: a path reads the entry's value in the rows of the header, and a name of the block
# reads that value for the entry's group.
function declare_settings(settings, header, names::Vector{Symbol}, input::Symbol)
    isempty(settings) && return nothing
    scales, templates, legend = Expr[], Pair{Symbol,Any}[], Expr[]
    for line in settings, (key, value) in last(call_arguments(line))
        line.args[1] === :scales ? push!(scales, :($(QuoteNode(key)) => $value)) :
        key in LEGEND_ROLES ? push!(templates, key => value) : push!(legend, Expr(:kw, key, value))
    end
    # The paths the texts read, each as a column of the rows of the header.
    read = Dict{String,Any}()
    for (_, template) in templates
        replace_reads(template, names; onpath=p -> (read[source_text(p)] = p), onname=identity)
    end
    statements, entry, rows = Expr[], gensym("entry"), gensym("rows")
    if !isempty(read)
        call = find_call(header, :mapping)
        mapped = call === nothing ? Pair{Symbol,Any}[] : last(call_arguments(call))
        reads = collect(values(read))
        has_data(header) && any(p -> length(path(p)) > 1, reads) &&
            error("A legend text of a plot of data(...) reads its columns by name, such as :Wafer")
        table, rewritten = header_table(Expr(:call, :mapping,
            Expr(:parameters, (Expr(:kw, role, value) for (role, value) in mapped)...), reads...), header, input)
        columns, roles = call_arguments(rewritten)
        column_of = Dict(source_text(p) => c for (p, c) in zip(reads, columns))
        push!(statements, :($rows = $LegendRows($Tables.columntable($table),
            Pair{Symbol,Any}[$((:($(QuoteNode(role)) => $value) for (role, value) in roles)...)])))
    end
    texts = map(templates) do (role, template)
        text = replace_reads(template, names; onpath=p -> :($entry_text($entry, $rows, $(column_of[source_text(p)]))),
            onname=name -> :($entry_values($name, $entry)))
        :($(QuoteNode(role)) => ($entry -> string($text)))
    end
    return (; statements, arguments=(:(Pair{Symbol,Any}[$(scales...)]), :(Pair{Symbol,Function}[$(texts...)]),
        Expr(:tuple, Expr(:parameters, legend...))))
end

# A legend text with each path `p` replaced by `onpath(p)` and each name of the block by
# `onname(name)`. The field of `contacts.Rc` is a name, not a path.
function replace_reads(template, names::Vector{Symbol}; onpath, onname)
    replaced(e) = path(e) !== nothing ? onpath(e) :
        e isa Symbol && e in names ? onname(e) :
        Meta.isexpr(e, :., 2) && e.args[2] isa QuoteNode ? Expr(:., replaced(e.args[1]), e.args[2]) :
        e isa Expr ? Expr(e.head, map(replaced, e.args)...) : e
    return replaced(template)
end

# The table of the values that `call`, a mapping of the header, names, and `call` with each value
# replaced by the name of its column: the header's own data, or the rows of each item of the input.
function header_table(call, header, input::Symbol)
    has_data(header) && return find_call(header, :data).args[2], call
    return tabulate(call, value -> per_item(value, input))
end

# The first call of `name` in an expression, such as `mapping(...)`, or `nothing`.
function find_call(expression, name::Symbol)
    Meta.isexpr(expression, :call) && expression.args[1] === name && return expression
    expression isa Expr || return nothing
    for argument in expression.args
        found = find_call(argument, name)
        found === nothing || return found
    end
    return nothing
end

# The positional arguments and the keyword arguments of a call, such as a mapping's values and its
# named roles: `([x, y], [role => value])`.
function call_arguments(call)
    positional, named = Any[], Pair{Symbol,Any}[]
    for a in call.args[2:end]
        if Meta.isexpr(a, :parameters)
            append!(named, [b.args[1] => b.args[2] for b in a.args])
        elseif Meta.isexpr(a, :kw)
            push!(named, a.args[1] => a.args[2])
        else
            push!(positional, a)
        end
    end
    return positional, named
end

# The expression with each `mapping` that names its positions, such as `mapping(; x=:gap, y=:R)`,
# written with positions, `mapping(:gap, :R)`, as AlgebraOfGraphics takes them.
# TODO: `y` alone, such as for a histogram along the vertical axis.
function positions_named(expression)
    expression isa Expr || return expression
    expression = Expr(expression.head, map(positions_named, expression.args)...)
    Meta.isexpr(expression, :call) && expression.args[1] === :mapping || return expression
    positional, named = call_arguments(expression)
    any(((name, _),) -> name in (:x, :y, :z), named) || return expression
    slots = Any[positional...]
    for (index, name) in enumerate((:x, :y, :z)), (other, value) in named
        other === name || continue
        index <= length(slots) && slots[index] !== nothing && error("`mapping` has $name twice: as a position and by name")
        append!(slots, fill(nothing, max(0, index - length(slots))))
        slots[index] = value
    end
    gap = findfirst(isnothing, slots)
    gap === nothing || error("`mapping` has $((:x, :y, :z)[findlast(!isnothing, slots)]) without $((:x, :y, :z)[gap])")
    rest = [Expr(:kw, name, value) for (name, value) in named if !(name in (:x, :y, :z))]
    return Expr(:call, :mapping, Expr(:parameters, rest...), slots...)
end

# `expression` with `call` replaced by `new`; the same object, not an equal one.
replace_call(expression, call, new) = expression === call ? new :
    expression isa Expr ? Expr(expression.head, map(e -> replace_call(e, call, new), expression.args)...) : expression

uses(expression, name::Symbol) = expression === name ||
    expression isa Expr && any(e -> uses(e, name), expression.args)
