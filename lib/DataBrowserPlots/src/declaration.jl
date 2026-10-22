"""
A plot whose values come from an input given when it is drawn, as `@plot` writes it without
`data(...)`. Draw it with `figure(declaration, input)`.
"""
struct Declaration
    # The AlgebraOfGraphics declaration for an input.
    layers::Function
end

# The latest world: code that the browser runs defines the declaration after the caller started.
figure(declaration::Declaration, input, args...; options...) =
    figure(Base.invokelatest(declaration.layers, input), args...; options...)

"""
A plot whose legend entries have their own labels, as a `label` in the visual of a
[`Statistic`](@ref) gives them. Draw it with `figure(plot)`.
"""
struct Labelled
    layers::Any
    # For each scale, such as `:Color`, its categories with their labels.
    categories::Dict{Symbol,Vector{Pair{Any,Any}}}
end

# The label of each group's legend entry: `labels(selection)` gives one label for each group of a
# statistic, as a `Selection`.
struct EntryLabels
    labels::Function
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

With a header and a block, each line of the block is a layer: each line is multiplied by the
header, and the lines are added, in order.

    @plot mapping(:gap, :R; color=:chip) begin
        visual(Scatter; markersize=6)
        linear(; interval=nothing) * subvisual(:prediction; linewidth=2)
    end

is `mapping(...) * (visual(Scatter; markersize=6) + linear(...) * subvisual(...))`. Write the
layers with `*` within a line; a line that continues on the next one ends with `*`.

With `data(table)`, the declaration is ordinary AlgebraOfGraphics over that table, and the names in
`mapping` are its columns. Draw it with `figure(declaration)`.

A layer with its own `data(...)` is not multiplied by the header, whose values would add to its own.
When that data is a vector of items, the names in its `mapping` are paths into those items, as for
the items the plot is drawn for.

`fit` fits a curve to the points of the header and draws it:

    resistance(gap; Rc, Rsh) = 2Rc + Rsh * gap

    @plot mapping(:gap, R(:data.V, :data.I); color=:Chip) begin
        visual(Scatter)
        fit(resistance, (Rc=1.0, Rsh=1.0)) * visual(Lines; label="\$(:Chip): Rc = \$(:Rc) Ω")
    end

The curve is a function of x with its parameters as keywords, and `fit` takes the curve and a
starting value for each parameter. The header's two positional values are x and y, and its
categorical named roles, here `color=:Chip`, divide the points into groups, with one fit each.
`fit` gives a [`Statistic`](@ref): one `Group` for each group of points. Its metadata holds the
group's values, such as `:Chip`, and each parameter, such as `:Rc`, a [`Parameter`](@ref) that
prints as the estimate ± one standard error. Its data is the drawn curve, and its members are the
items whose points it fits. `fit(...; xlim=(0, 25))` draws the curve over that range of x instead
of over the fitted points. With `data(table)` in the header, `fit` takes the rows of that table.

The visual draws the fit on the axes of the points and in the roles of its group, so the group's
legend entry shows its points and its curve. Without a visual, a fit is drawn with `Lines`. A
`label` in the visual names each group's legend entry, and its paths read the values of that
group's fit.

A line `name = value` gives a name to a value for the lines after it, such as a fit drawn twice:

    contacts = fit(resistance, (Rc=1.0, Rsh=1.0))
    contacts * visual(Lines; label="Rc = \$(:Rc)")
    contacts * visual(Scatter; markersize=4)

A line that uses a name, or that calls `fit`, is not multiplied by the header: the fit already
holds what the header maps.
"""
macro plot(header, block)
    Meta.isexpr(block, :block) || error("@plot takes a header and a `begin ... end` block of layers")
    lines = filter(line -> !(line isa LineNumberNode), block.args)
    statements = filter(line -> Meta.isexpr(line, :(=)), lines)
    names = Symbol[first(statement.args) for statement in statements]
    # A line that draws a fit, or its own data, stands alone: the header's values would add to its own.
    drawn = map(filter(line -> !Meta.isexpr(line, :(=)), lines)) do line
        draws_fit = find_call(line, :fit) !== nothing || any(name -> uses(line, name), names)
        draws_fit ? entry_labels(line) : has_data(line) ? line : :($header * $line)
    end
    # `a + b + c`, not `+(a, b, c)`: AoG adds two layers at a time and has no `+` of one layer.
    declaration = isempty(drawn) ? header : foldl((a, b) -> :($a + $b), drawn)
    input = gensym("input")
    if uses(block, :fit)
        pushfirst!(statements, :(fit = $(define_fit(header, input))))
    end
    return esc(declare(declaration, statements; input))
end

macro plot(declaration)
    return esc(declare(declaration))
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

# The paths in an expression, outermost first.
paths(expression)::Vector{Vector{Symbol}} = path(expression) !== nothing ? [path(expression)] :
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
# when it is a vector of items, and the layer is left as it is for any other value.
function declare_layer(layer, input::Symbol)
    own = find_call(layer, :data)
    if own === nothing
        tabulated = tabulate(layer, value -> per_item(value, input))
        tabulated === nothing && return layer
        table, rewritten = tabulated
        return :(data($table) * $rewritten)
    end
    value, items = gensym("data"), gensym("items")
    tabulated = tabulate(layer, v -> per_item(v, items))
    plain = replace_call(layer, own, :(data($value)))
    tabulated === nothing && return plain
    table, rewritten = tabulated
    return :(let $value = $(own.args[2])
        $value isa AbstractVector{<:$AbstractDataItem} ?
            (let $items = $(Workspace.select)($value); $(replace_call(rewritten, find_call(rewritten, :data), :(data($table)))) end) :
            $plain
    end)
end

# The layers of a declaration, each with its own table, after the `statements`, which define names
# for them. The result is a function of the input when a layer or a statement reads it.
function declare(declaration, statements=Expr[]; input::Symbol=gensym("input"))
    drawn = foldl((a, b) -> :($a + $b), map(layer -> declare_layer(layer, input), layers(declaration)))
    body = isempty(statements) ? drawn : Expr(:let, Expr(:block), Expr(:block, statements..., drawn))
    return uses(body, input) ? :($Declaration($input -> $body)) : body
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

# `expression` with `call` replaced by `new`; the same object, not an equal one.
replace_call(expression, call, new) = expression === call ? new :
    expression isa Expr ? Expr(expression.head, map(e -> replace_call(e, call, new), expression.args)...) : expression

# The line with the `label` of its `visual` read for each group of a statistic, when the label
# holds paths: `"Rc = \$(:Rc)"` gives one label for each group.
function entry_labels(line)
    call = find_call(line, :visual)
    call === nothing && return line
    _, named = call_arguments(call)
    index = findfirst(((name, value),) -> name === :label && !isempty(paths(value)), named)
    index === nothing && return line
    selection = gensym("selection")
    labels = :($EntryLabels($selection -> $(per_item(last(named[index]), selection))))
    arguments = map(call.args) do a
        Meta.isexpr(a, :kw) && a.args[1] === :label ? Expr(:kw, :label, labels) :
        Meta.isexpr(a, :parameters) ? Expr(:parameters, (Meta.isexpr(b, :kw) && b.args[1] === :label ?
            Expr(:kw, :label, labels) : b for b in a.args)...) : a
    end
    return replace_call(line, call, Expr(:call, arguments...))
end

uses(expression, name::Symbol) = expression === name ||
    expression isa Expr && any(e -> uses(e, name), expression.args)

# `fit(curve, starts; options...)` over the points of the header: the header's positional values
# are x and y, and its named roles form the groups. Without `data(...)` in the header, the points
# are the items of the input.
function define_fit(header, input::Symbol)
    call = find_call(header, :mapping)
    call === nothing && return :((_...; _...) -> error("fit needs a header that maps x and y, such as mapping(:x, :y)"))
    item = gensym("item")
    if has_data(header)
        table, rewritten = find_call(header, :data).args[2], call
        members = :(NamedTuple())
    else
        table, rewritten = tabulate(call, value -> per_item(value, input))
        push!(table.args[2].args, Expr(:kw, item, :($input.id)))
        members = :((; members=$(Workspace.items)($input), item=$(QuoteNode(item))))
    end
    positional, named = call_arguments(rewritten)
    roles = [:($(QuoteNode(role)) => $value) for (role, value) in named]
    return :((curve, starts; options...) -> $fit_statistic(curve, starts, $table, Any[$(positional...)],
        Pair{Symbol,Any}[$(roles...)]; $members..., options...))
end
