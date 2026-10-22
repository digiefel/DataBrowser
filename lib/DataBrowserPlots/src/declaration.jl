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

TODO: named layers, `fit = linear(...)`, whose results the following lines use (roadmap 0.11.0).
"""
macro plot(header, block)
    Meta.isexpr(block, :block) || error("@plot takes a header and a `begin ... end` block of layers")
    layers = filter(line -> !(line isa LineNumberNode), block.args)
    for layer in layers
        Meta.isexpr(layer, :(=)) && error("@plot does not name layers yet: $layer")
    end
    # `a + b + c`, not `+(a, b, c)`: AoG adds two layers at a time and has no `+` of one layer.
    declaration = isempty(layers) ? header : :($header * $(foldl((a, b) -> :($a + $b), layers)))
    return esc(declare(declaration))
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

# Replace each value a `mapping` names that holds a path with `f(value)`. A label or a
# transformation after `=>` stays.
function map_mapped(f, expression)
    expression isa Expr || return expression
    if Meta.isexpr(expression, :call) && expression.args[1] === :mapping
        mapped(value) = Meta.isexpr(value, :call) && value.args[1] === :(=>) ?
            Expr(:call, :(=>), mapped(value.args[2]), value.args[3:end]...) :
            isempty(paths(value)) ? value : f(value)
        argument(a) = Meta.isexpr(a, :kw) ? Expr(:kw, a.args[1], mapped(a.args[2])) :
            Meta.isexpr(a, :parameters) ? Expr(:parameters, map(argument, a.args)...) : mapped(a)
        return Expr(:call, :mapping, map(argument, expression.args[2:end])...)
    end
    return Expr(expression.head, map(e -> map_mapped(f, e), expression.args)...)
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

# One layer as a function of the input: each value its `mapping` names becomes a column of `unnest`
# over the input, and the mapping names that column.
function declare_layer(layer, input::Symbol)
    values = Dict{String,Any}()
    order = String[]
    map_mapped(layer) do value
        text = source_text(value)
        haskey(values, text) || (values[text] = value; push!(order, text))
        return value
    end
    isempty(order) && return layer
    # A path's column is named after its last part, unless another column has that name too.
    short(t) = path(values[t]) === nothing ? t : String(last(path(values[t])))
    names = Dict(t => Symbol(count(==(short(t)), map(short, order)) == 1 ? short(t) : lstrip(t, ':'))
        for t in order)
    columns = [Expr(:kw, names[t], per_item(values[t], input)) for t in order]
    rewritten = map_mapped(value -> QuoteNode(names[source_text(value)]), layer)
    table = Expr(:call, Workspace.unnest, Expr(:parameters, columns...))
    return :(data($table) * $rewritten)
end

# Without `data(...)`, the declaration becomes a function of the input, with a table for each layer:
# the values of one layer broadcast together, and the layers are drawn together.
function declare(declaration)
    (has_data(declaration) || isempty(paths(declaration))) && return declaration
    input = gensym("input")
    sum = foldl((a, b) -> :($a + $b), map(layer -> declare_layer(layer, input), layers(declaration)))
    return :($Declaration($input -> $sum))
end
