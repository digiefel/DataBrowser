"""
The functions to apply to the y values of a layer's points that share x and their groups, as
`aggregate(mean, std)` in [`@plot`](@ref) writes them. The aggregate is done when the layer has its
points, and gives a [`Result`](@ref) with the value of each function under its name.
"""
# The types of the functions are part of the type of the aggregate, so the workspace computes it
# again when their code changes (`DataBrowserCore.CodeRevisions`).
struct Aggregate{F<:Tuple}
    functions::F
    Aggregate(functions...) = new{typeof(functions)}(functions)
end

# The name of a function's value in a group's metadata, such as `:mean`.
# TODO: an anonymous function, such as `v -> std(v) / sqrt(length(v))`, is named `#1`.
function_name(f) = Symbol(nameof(f))

# The aggregate over the points of `table`, whose columns `positional` maps to x and y: one group for
# each x and each group of the categorical roles in `named`, sorted by x, then by those roles. Each
# group's metadata holds its x, its roles' values, the value of each function and the `count` of its
# points; its data holds its x and those values, one column each; its members are the items of
# `source` whose rows it takes.
# The functions take the y values after `scale`, the function of the y axis, such as `log10`, and
# their values stay as they give them: the result's `scaled` values.
function Result(aggregate::Aggregate, table, positional::Vector, named::Vector, source; scale=identity)::Result
    length(positional) == 2 || error("aggregate needs the points to map two positional values, x and y")
    columns = Tables.columntable(table)
    members = haskey(columns, ITEM) ? Workspace.items(source) : AbstractDataItem[]
    roles = grouping(named, columns)
    x, y = column.(positional)
    keyed = unique([x; Symbol[column(v) for (_, v) in roles]])
    keys = [NamedTuple{Tuple(keyed)}(Tuple(columns[k][row] for k in keyed)) for row in eachindex(columns[x])]
    names = function_name.(aggregate.functions)
    groups = map(sort(unique(keys))) do key
        rows = [row for row in eachindex(keys) if keys[row] == key && columns[y][row] isa Real && isfinite(scaled(scale, columns[y][row]))]
        values = [f(scaled.(scale, Float64.(columns[y][rows]))) for f in aggregate.functions]
        name = join(("$k = $v" for (k, v) in pairs(key)), ", ")
        taken = haskey(columns, ITEM) ? AbstractDataItem[members[sort(unique(columns[ITEM][rows]))]...] : AbstractDataItem[]
        Group(name, Dict{Symbol,Any}(pairs(key)..., (names .=> values)..., :count => length(rows)),
            NamedTuple{(:x, names...)}(([key[x]], ([v] for v in values)...)), taken)
    end
    return Result(aggregate, groups, positional, roles; scale)
end

# The result of an aggregate already done, as `groups`, drawn as points.
Result(aggregate::Aggregate, groups::Vector{Group}, positional::Vector, roles::Vector; scale=identity) =
    Result(groups, positional, roles, :Scatter, scale, collect(Symbol, function_name.(aggregate.functions)))
