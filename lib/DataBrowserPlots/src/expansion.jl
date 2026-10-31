# How `@plot` turns its declaration into code: each value that a `mapping` names becomes a column of
# a table of the input's items, and each line becomes a layer of the header, as a function of the
# input.

# Preserve the yN identities before positions_named packs their values into one AoG position.
function y_roles(expression)
    call = find_call(expression, :mapping)
    call === nothing && return nothing
    positional, named = call_arguments(call)
    roles = Symbol[key === :y1 ? :y : key for (key, _) in named if is_y_scale(key)]
    length(positional) >= 2 && push!(roles, :y)
    isempty(roles) && return nothing
    sort!(roles; by=role -> role === :y ? 1 : parse(Int, String(role)[2:end]))
    return roles
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
        # A list of values, as `y` and `y2` give, has each of them.
        mapped(value) = Meta.isexpr(value, :call) && value.args[1] === :(=>) ?
            Expr(:call, :(=>), mapped(value.args[2]), value.args[3:end]...) :
            Meta.isexpr(value, :vect) ? Expr(:vect, map(mapped, value.args)...) :
            chosen(value) ? f(value) : value
        argument(a) = Meta.isexpr(a, :kw) ? Expr(:kw, a.args[1], mapped(a.args[2])) :
            Meta.isexpr(a, :parameters) ? Expr(:parameters, map(argument, a.args)...) : mapped(a)
        return Expr(:call, :mapping, map(argument, expression.args[2:end])...)
    end
    return Expr(expression.head, map(e -> map_mapped(f, e; chosen), expression.args)...)
end

# The values of the path `names` for each item of `input`, such as `input.data.V`.
reading(names, input::Symbol) = foldl((e, name) -> Expr(:., e, QuoteNode(name)), names; init=input)

# A formula as a function of the values of its paths, and the values of each path for the items of
# `input`: `resistance(:data.V, :data.I)` is `(V, I) -> resistance(V, I)` of `input.data.V` and
# `input.data.I`.
function formula(value, input::Symbol)
    found = paths(value)
    arguments = [gensym(join(names, '_')) for names in found]
    replaced(e) = path(e) in found ? arguments[findfirst(==(path(e)), found)] :
        e isa Expr ? Expr(e.head, map(replaced, e.args)...) : e
    return :(($(arguments...),) -> $(replaced(value))), [reading(names, input) for names in found]
end

# The values of a mapped value for each item of `input`. A formula runs once per item, with each
# path replaced by that item's value.
function per_item(value, input::Symbol)
    path(value) === nothing || return reading(path(value), input)
    f, readings = formula(value, input)
    return :(map($f, $(readings...)))
end

# The type of the values that a mapped value gives the points of the items of `input`, as Julia
# infers it from the types of the values its paths read, without running it; `Any` when it is not
# known. An item's vector gives one value to each of its points. A title after `=>` stays out, and
# a function after it applies to each value.
# TODO: a path into the items' data, such as `:data.I`, is of type `Any` until an item's data is
# read, as `selection.data` holds the data of any item. Core could know the type of the data of each
# kind of item, for example by inferring it from the project's `read` and `process`.
function per_item_type(value, input::Symbol)
    if Meta.isexpr(value, :call) && value.args[1] === :(=>)
        inner, after = per_item_type(value.args[2], input), value.args[3]
        (after isa String || Meta.isexpr(after, :string)) && return inner
        f = Meta.isexpr(after, :call) && after.args[1] === :(=>) ? after.args[2] : after
        return :($Base.infer_return_type($f, Tuple{$inner}))
    end
    isempty(paths(value)) && return Any
    path(value) === nothing || return :($point_type(eltype($(reading(path(value), input)))))
    f, readings = formula(value, input)
    return :($point_type($Base.infer_return_type($f, Tuple{$((:(eltype($r)) for r in readings)...)})))
end
point_type(T::Type) = T <: AbstractVector ? eltype(T) : T

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
    return Expr(:call, Workspace.unnest, Expr(:parameters, columns...)), rewritten, names
end

# The `Points` of a layer, as an expression of the input, or `nothing` without a fit or an aggregate.
# The code of the step is its text without line numbers, so a new line in it changes nothing.
function points(layer, table, names, input::Symbol)
    step = something(find_call(layer, :fit), find_call(layer, :aggregate), Some(nothing))
    step === nothing && return nothing
    texts = (:($(QuoteNode(name)) => $text) for (text, name) in names)
    return :($Points($(string(Base.remove_linenums!(copy(step)))), Dict{Symbol,String}($(texts...)), $input -> $table))
end

# One layer as a function of the input: each value its `mapping` names becomes a column of `unnest`
# over the input, and the mapping names that column. With `data(value)`, the paths read `value`
# when it is a selection, and the layer is left as it is for any other value. A fit in the
# layer is done over its points (`resolve`), which know their items by the `ITEM` column.
function declare_layer(layer, input::Symbol)
    with_items(table, items) = Expr(table.head, table.args[1], Expr(:parameters, table.args[2].args..., :($item_places($items)...)))
    own = find_call(layer, :data)
    if own === nothing
        tabulated = tabulate(layer, value -> per_item(value, input))
        tabulated === nothing && return :($resolve($layer, nothing, $AXES))
        table, rewritten, names = tabulated
        table = with_items(table, input)
        return :($resolve(data($table) * $rewritten, $input, $AXES, $(points(layer, table, names, input))))
    end
    value, items = gensym("data"), gensym("items")
    tabulated = tabulate(layer, v -> per_item(v, items))
    tabulated === nothing && return :($resolve($layer, nothing, $AXES))
    plain = replace_call(layer, own, :(data($value)))
    table, rewritten, _ = tabulated
    of_items = replace_call(rewritten, find_call(rewritten, :data), :(data($(with_items(table, items)))))
    return :(let $value = $(own.args[2])
        $value isa $Selection ?
            (let $items = $value; $resolve($of_items, $items, $AXES) end) :
            $resolve($plain, nothing, $AXES)
    end)
end

# A drawn line as a function of the input. A line that reads the values of a named result, such as
# `mapping(result.gap, result.count) * visual(Scatter)`, is drawn over the result's groups, one row
# each, in the roles of the result's points; any other line is a layer of the header.
function declare_line(header, line, names::Vector{Symbol}, input::Symbol)
    found = Symbol[]
    reads(e) = Meta.isexpr(e, :., 2) && e.args[1] in names && e.args[2] isa QuoteNode
    visit(e) = (reads(e) && push!(found, e.args[1]); e isa Expr && foreach(visit, e.args))
    visit(line)
    isempty(found) && return declare_layers(:($inherit($header, $line)), input)
    length(unique(found)) == 1 || error("A line reads the values of one named result, not of $(join(unique(found), " and "))")
    result = first(found)
    # `result.count` is the path `:count` into each group of `result`.
    paths_of(e) = reads(e) ? e.args[2] : e isa Expr ? Expr(e.head, map(paths_of, e.args)...) : e
    tabulated = tabulate(paths_of(line), value -> per_item(value, result))
    tabulated === nothing && return declare_layers(:($inherit($header, $line)), input)
    table, rewritten = tabulated
    return :($over_result($result, $table, $rewritten))
end

# The declared layers of `expression`, added.
declare_layers(expression, input::Symbol) =
    foldl((a, b) -> :($a + $b), map(layer -> declare_layer(layer, input), layers(expression)))

# The declared layers, `drawn`, after the `statements`, which define names for them. The result is
# a function of the input when a layer or a statement reads it. `settings` are the statements and
# the arguments of `Scaled` that the scales and legend lines give, or `nothing`. `types` are the
# `role => type` pairs of the roles' values, which read the input.
function declare(drawn, statements=Expr[]; input::Symbol, settings=nothing, types=Expr[])
    if settings !== nothing
        statements = [statements; settings.statements]
        drawn = :($Scaled($drawn, $(settings.arguments...)))
    end
    body = isempty(statements) ? drawn : Expr(:let, Expr(:block), Expr(:block, statements..., drawn))
    return uses(body, input) ? :($Declaration($input -> $body, $input -> Pair{Symbol,Any}[$(types...)])) : body
end

# The `scales(...)`, `legend(...)` and `theme(...)` lines as the arguments of `Scaled` after its layers, and the
# statements they need, or `nothing` if there are none. A legend text becomes a function of a
# `LegendEntry`: a path reads the entry's value in the rows of the header, and a name of the block
# reads that value for the entry's group.
function declare_settings(settings, header, names::Vector{Symbol}, input::Symbol)
    isempty(settings) && return nothing
    scales, templates, legend, theme, coords = Expr[], Pair{Symbol,Any}[], Expr[], nothing, Expr[]
    for line in filter(line -> line.args[1] === :theme, settings)
        base, named = call_arguments(line)
        theme = :($PlotTheme($(isempty(base) ? nothing : only(base)), $(Expr(:tuple, Expr(:parameters, (Expr(:kw, k, v) for (k, v) in named)...)))))
    end
    for line in filter(line -> line.args[1] === :coord, settings)
        positional, named = call_arguments(line)
        # TODO: `polar` and a tilt of the drawn axes; the plan is at `figure(plot::Scaled)` in the AlgebraOfGraphics extension.
        length(positional) <= 1 || error("coord takes one function of the points, such as `coord((x, y) -> (y, x))`")
        points = [Expr(:kw, :points, f) for f in positional]
        push!(coords, Expr(:tuple, Expr(:parameters, points..., (Expr(:kw, k, v) for (k, v) in named)...)))
    end
    for line in filter(line -> !(line.args[1] in (:theme, :coord)), settings), (key, value) in last(call_arguments(line))
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
        Expr(:tuple, Expr(:parameters, legend...)), theme, :(NamedTuple[$(coords...)])))
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
# written with positions, `mapping(:gap, :R)`, as AlgebraOfGraphics takes them. A `y` without `x`
# keeps `nothing` as its `x`: a line takes the header's `x` there, and drawing reads it as `y` alone.
# `y2`, `y3` and so on add values to `y`, which `y1` also names: the position is then their list,
# `[y, y2]`, and `ydims()` maps which of them a point comes from, as AlgebraOfGraphics' `dims(1)`.
# TODO: several values of `x`, paired with those of `y` or with each of them.
function positions_named(expression)
    expression isa Expr || return expression
    expression = Expr(expression.head, map(positions_named, expression.args)...)
    Meta.isexpr(expression, :call) && expression.args[1] === :mapping || return expression
    positional, named = call_arguments(expression)
    # The position and the number of a named position, such as `(2, 3)` for `y3`, or `nothing`.
    function position(name::Symbol)
        found = match(r"^([xyz])(\d*)$", String(name))
        found === nothing && return nothing
        return findfirst(==(found[1]), ("x", "y", "z")), isempty(found[2]) ? 1 : parse(Int, found[2])
    end
    any(((name, _),) -> position(name) !== nothing, named) || return expression
    slots = Any[positional...]
    for index in 1:3
        values = sort([(position(name)[2], name, value) for (name, value) in named
            if position(name) !== nothing && position(name)[1] == index])
        isempty(values) && continue
        # A position written by place is the first value, such as y in `mapping(:gap, :R; y2=:R2)`.
        index <= length(slots) && slots[index] !== nothing && pushfirst!(values, (1, :place, slots[index]))
        numbers = first.(values)
        allunique(numbers) || error("`mapping` has the same position twice, such as y and y1, or y by place and by name")
        index != 2 && length(values) > 1 && error("`mapping` takes several values of y, but not yet of $(("x", "y", "z")[index])")
        append!(slots, fill(nothing, max(0, index - length(slots))))
        slots[index] = length(values) == 1 ? values[1][3] : Expr(:vect, last.(values)...)
    end
    gap = findfirst(isnothing, slots[2:end])
    gap === nothing || error("`mapping` has z without y")
    ydims(e) = Meta.isexpr(e, :call) && e.args == [:ydims] ? :(dims(1)) : e isa Expr ? Expr(e.head, map(ydims, e.args)...) : e
    rest = [Expr(:kw, name, ydims(value)) for (name, value) in named if position(name) === nothing]
    return Expr(:call, :mapping, Expr(:parameters, rest...), slots...)
end

# `expression` with `call` replaced by `new`; the same object, not an equal one.
replace_call(expression, call, new) = expression === call ? new :
    expression isa Expr ? Expr(expression.head, map(e -> replace_call(e, call, new), expression.args)...) : expression

uses(expression, name::Symbol) = expression === name ||
    expression isa Expr && any(e -> uses(e, name), expression.args)
