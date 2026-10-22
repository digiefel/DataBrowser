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

A line may fit a curve to the points of the header, and name the result:

    resistance(gap; Rc, Rsh) = 2Rc + Rsh * gap

    @plot mapping(:gap, R(:data.V, :data.I); color=:Chip) begin
        visual(Scatter)
        contacts = fit(resistance, (Rc=1.0, Rsh=1.0)) * visual(Lines; label="Rc = \$(contacts.Rc)")
        mapping(contacts.x[end], contacts.y[end]) * visual(Text; text="Rsh = \$(contacts.Rsh)")
    end

The curve is a function of x with its parameters as keywords, and `fit` takes the curve and a
starting value for each parameter. The header's named roles, here `color=:Chip`, divide the points
into groups, and each group has its own fit. A line that uses the name is drawn once for each
group, with the name set to that group's [`Fit`](@ref): `contacts.Rc` is a [`Parameter`](@ref),
which prints as the estimate ± one standard error; `contacts.Chip` is the group's chip; and
`contacts.x` and `contacts.y` are the drawn curve. `fit(...; xlim=(0, 25))` draws the curve over
that range of x instead of over the fitted points. With `data(table)` in the header, the fits take the rows of that table.
"""
macro plot(header, block)
    Meta.isexpr(block, :block) || error("@plot takes a header and a `begin ... end` block of layers")
    layers = filter(line -> !(line isa LineNumberNode), block.args)
    any(layer -> Meta.isexpr(layer, :(=)), layers) && return esc(declare_fits(header, layers))
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
# over the input, and the mapping names that column.
function declare_layer(layer, input::Symbol)
    tabulated = tabulate(layer, value -> per_item(value, input))
    tabulated === nothing && return layer
    table, rewritten = tabulated
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

# The column a rewritten mapping value names: `:R` in `:R` and in `:R => "R (Ω)"`.
column_name(value) = Meta.isexpr(value, :call) && value.args[1] === :(=>) ? column_name(value.args[2]) : value.value

uses(expression, name::Symbol) = expression === name ||
    expression isa Expr && any(e -> uses(e, name), expression.args)

# With named fit lines, `name = fit(curve, starts; xlim) * visual(...)`. The header's positional
# values are the points that each fit takes, and its named roles, such as `color=:Chip`, form the
# groups: one fit for each group. A line that uses a fit's name is drawn once for each group, with
# the name set to that group's `Fit`, and with the group's values in the header's named roles.
# With `data(table)` in the header, the fits take the rows of that table.
function declare_fits(header, lines)
    # TODO: lines that use a fit and also a path; a fit inside a line's own mapping; fits that use
    # other fits.
    own_data = has_data(header)
    input = gensym("input")
    if own_data
        table, header_mapping = find_call(header, :data).args[2], find_call(header, :mapping)
    else
        tabulated = tabulate(find_call(header, :mapping), value -> per_item(value, input))
        tabulated === nothing && error("@plot with a fit needs a header that maps paths, such as mapping(:x, :y)")
        table, header_mapping = tabulated
    end
    positional, named = call_arguments(header_mapping)
    length(positional) == 2 || error("A fit needs the header to map two positional values, x and y")
    x, y = column_name.(positional)
    roles = [role => column_name(value) for (role, value) in named]
    # TODO: group only by categorical roles; a continuous color should not split the points.
    group = Expr(:vect, (QuoteNode(column) for (_, column) in roles)...)

    rows = gensym("rows")
    names = Symbol[]
    # For each fit's name, the variable that holds its fits, one for each group.
    groups = Dict{Symbol,Symbol}()
    computed = Expr[:($rows = $table)]
    drawn = Any[]
    for line in lines
        if Meta.isexpr(line, :(=))
            name, value = line.args
            factors = Meta.isexpr(value, :call) && value.args[1] === :* ? value.args[2:end] : [value]
            index = findfirst(f -> Meta.isexpr(f, :call) && f.args[1] === :fit, factors)
            index === nothing && error("A named line of @plot is a fit, such as `$name = fit(curve, starts)`: $line")
            call = factors[index]
            arguments, options = call_arguments(call)
            options = [Expr(:kw, option, value) for (option, value) in options]
            length(arguments) == 2 || error("fit takes a curve and its starting values: `fit(curve, (a=1.0, b=1.0))`")
            push!(names, name)
            groups[name] = gensym("$(name)_groups")
            push!(computed, :($(groups[name]) = $fit_groups($(Expr(:parameters, options...)),
                $(arguments...), $rows, $(QuoteNode(x)), $(QuoteNode(y)), Symbol[$(group.args...)])))
            others = [f for (i, f) in enumerate(factors) if i != index]
            # The curve of each group, with the group's values in the header's named roles.
            curve = Expr(:tuple, Expr(:parameters,
                Expr(:kw, x, :(getfield($name, :x))), Expr(:kw, y, :(getfield($name, :y))),
                (Expr(:kw, column, :(fill(getfield($name, :group)[$(QuoteNode(column))], length(getfield($name, :x)))))
                    for (_, column) in roles)...))
            layer = foldl((a, b) -> :($a * $b), [:(data($curve) * $header_mapping);
                isempty(others) ? [:(visual(Lines))] : others])
            push!(drawn, (name, layer))
        else
            push!(drawn, (nothing, line))
        end
    end

    sums = map(drawn) do (own, line)
        fits = own !== nothing ? [own] : filter(name -> uses(line, name), names)
        isempty(fits) && own_data && return :($header * $line)
        isempty(fits) &&
            return foldl((a, b) -> :($a + $b), map(layer -> declare_layer(layer, input), layers(:($header * $line))))
        length(fits) == 1 || error("A line of @plot uses one fit at most: $line")
        used = only(fits)
        if own === nothing
            # The values that use the fit are a table with one row for each group, which also
            # holds the group's values in the header's named roles.
            tabulated = tabulate(line, value -> :([$value]); chosen=value -> uses(value, used))
            if tabulated !== nothing
                table, line = tabulated
                group_columns = [Expr(:kw, column, :([getfield($used, :group)[$(QuoteNode(column))]])) for (_, column) in roles]
                append!(table.args[2].args, group_columns)
                call = find_call(line, :mapping)
                given = first.(call_arguments(call)[2])
                append!(call.args, [Expr(:kw, role, QuoteNode(column)) for (role, column) in roles if role ∉ given])
                line = :(data($table) * $line)
            end
        end
        return :(foldl(+, map($used -> $line, $(groups[used]))))
    end
    sum = foldl((a, b) -> :($a + $b), sums)
    own_data && return :(begin
        $(computed...)
        $sum
    end)
    return :($Declaration($input -> begin
        $(computed...)
        $sum
    end))
end
