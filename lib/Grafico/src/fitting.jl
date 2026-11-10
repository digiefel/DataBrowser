"""
    unnest(; name = values, ...) -> NamedTuple of vectors

Put the data of several items together in one table, with one column for each keyword. Each value
has one entry for each item, such as `items.device` or `items.data.V`. The entries of one item
broadcast together, as in a Julia expression: a column of the data of the item gives one row for
each of its entries, and a single value, such as the device of the item, repeats on each of those
rows.
"""
function unnest(; columns...)
    names = keys(columns)
    values = Tuple(Base.values(columns))
    isempty(values) && return NamedTuple()
    count = length(first(values))
    all(value -> length(value) == count, values) ||
        error("unnest: each value needs one entry per item; the lengths are $(map(length, values))")
    collected = [Any[] for _ in names]
    for index in 1:count
        rows = broadcast(tuple, (value[index] for value in values)...)
        for row in (rows isa Tuple ? (rows,) : rows), (column, entry) in zip(collected, row)
            push!(column, entry)
        end
    end
    return NamedTuple{Tuple(names)}(Tuple(identity.(column) for column in collected))
end

# The column of a layer's table that holds the place of each row's item in its input.
const ITEM = Symbol("#item")

"""
    unnest_items(items; columns...) -> NamedTuple of vectors

Build the table for a layer over `items`. Packages such as DataBrowserPlots specialize this hook to
attach item indices for workspace computations.
"""
unnest_items(_; columns...) = unnest(; columns...)

"""
    least_squares(curve, x, y, starts; scale=identity) -> (estimates, errors)

Fit `curve`, a function of x with its parameters as keywords, to the points `x`, `y`. `starts`
gives a starting value for each parameter. Returns the least-squares estimate of each parameter,
in the order of `starts`, and one standard error for each, from the covariance scaled by the
residuals. The residuals are measured after `scale`, the function of the y axis, such as `log10`.
"""
function least_squares(curve, x::Vector{Float64}, y::Vector{Float64}, starts::NamedTuple; scale=identity)
    names = keys(starts)
    residual(p, _) = scale.(curve.(x; NamedTuple{names}(Tuple(p))...)) .- scale.(y)
    problem = NonlinearLeastSquaresProblem(residual, collect(Float64, values(starts)))
    solution = solve(problem, LevenbergMarquardt())
    SciMLBase.successful_retcode(solution) || error("the fit did not converge ($(solution.retcode))")
    free = length(x) - length(names)
    free > 0 || error("$(length(x)) points cannot fit $(length(names)) parameters")
    J = ForwardDiff.jacobian(p -> residual(p, nothing), solution.u)
    covariance = inv(J' * J) * sum(abs2, solution.resid) / free
    return solution.u, sqrt.(max.(diag(covariance), 0.0))
end

function solve_fit(curve, x::Vector{Float64}, y::Vector{Float64}, starts::NamedTuple; scale=identity)::NamedTuple
    estimates, errors = least_squares(curve, x, y, starts; scale)
    return NamedTuple{keys(starts)}(Tuple(measurement.(estimates, errors)))
end

# One fit for each group of `rows`, a Tables.jl table: the rows with equal values in the `group`
# columns. Each fit holds the group's values, the parameters, and the curve, as columns `x` and `y`,
# under `curve`. The curve is drawn over the fitted x values, or over `xlim`. `scale` is the function
# of the y axis; a point it has no value for, such as a negative y of `log10`, is left out.
function fit_groups(curve, starts::NamedTuple, rows, x::Symbol, y::Symbol, group::Vector{Symbol};
        xlim=nothing, scale=identity)::Vector{NamedTuple}
    table = Tables.columntable(rows)
    keys = [NamedTuple{Tuple(group)}(Tuple(table[g][row] for g in group)) for row in eachindex(table[x])]
    return map(unique(keys)) do key
        rows = [row for row in eachindex(keys) if keys[row] == key &&
            table[x][row] isa Real && table[y][row] isa Real && isfinite(table[x][row]) && isfinite(scaled(scale, table[y][row]))]
        xs, ys = Float64.(table[x][rows]), Float64.(table[y][rows])
        name = string(nameof(curve), isempty(key) ? "" : " for " * join(("$k = $v" for (k, v) in pairs(key)), ", "))
        parameters = try
            solve_fit(curve, xs, ys, starts; scale)
        catch err
            error("Fitting $name: $(sprint(showerror, err))")
        end
        low, high = xlim === nothing ? extrema(xs) : xlim
        curve_x = collect(range(low, high; length=100))
        curve_y = curve.(curve_x; map(Measurements.value, parameters)...)
        return merge(key, parameters, (; curve=(x=curve_x, y=curve_y)))
    end
end

"""
What a line of [`@plot`](@ref) computes from its points, such as the curves and parameters of
`fit`: one named tuple for each group of points. It is a vector of those groups.

Multiply it by a `visual` to draw it: its data is drawn on the axes of the points, in the named
roles of their groups, such as `color`, so that it shares their legend entries. Alone, it is drawn
with its own visual, `Lines` for a fit.

A name in its groups reads one value for each group: `contacts.Rc` is the parameter `Rc` of each
fit.
"""
struct Result <: AbstractVector{NamedTuple}
    groups::Vector{NamedTuple}
    ## The values the points mapped to x and y, as `mapping` takes them, such as `:gap => "gap (µm)"`.
    positional::Vector{Any}
    ## The named roles that form the groups, such as `:color => :Chip`.
    named::Vector{Pair{Symbol,Any}}
    ## The plot type it is drawn with when no visual is given, a name in Makie.
    plottype::Symbol
    ## The function of the y axis, such as `log10`, that the values named `scaled` were computed
    ## after, such as an aggregate's `mean`. Drawing places them back on the axis.
    scale::Any
    scaled::Vector{Symbol}
end
Result(groups, positional, named, plottype) = Result(groups, positional, named, plottype, identity, Symbol[])
Base.size(result::Result) = size(getfield(result, :groups))
Base.getindex(result::Result, index::Int) = getfield(result, :groups)[index]
# A value of each group, such as `contacts.Rc` or `result.count`: one for each group.
Base.getproperty(result::Result, name::Symbol) = [group[name] for group in getfield(result, :groups)]
Base.propertynames(result::Result) = unique(reduce(vcat, [collect(keys(group)) for group in getfield(result, :groups)]; init=Symbol[]))

"""
A curve to fit to the points of a layer, as `fit(curve, starts; options...)` in [`@plot`](@ref)
writes it. The fit is done when the layer has its points, and gives a [`Result`](@ref).
"""
struct Fit{C}
    curve::C
    starts::NamedTuple
    options::NamedTuple
end
Fit(curve, starts::NamedTuple; options...) = Fit(curve, starts, NamedTuple(options))

# The fit's result over the points of a layer: `table`, whose columns `positional` and `named`
# map. `scale` is the function of the y axis, after which the residuals are measured.
Result(fit::Fit, table::NamedTuple, positional::Vector, named::Vector; scale=identity)::Result =
    fit_result(fit.curve, fit.starts, table, positional, named; scale, fit.options...)

# The value of `scale` at `value`, or `NaN` where it has none, such as `log10` of a negative value.
scaled(scale, value) = try
    scale(value)
catch err
    err isa DomainError ? NaN : rethrow()
end

# The column a value of `mapping` names: `:R` in `:R`, in `:R => "R (Ω)"` and in `:R => f => "R"`.
column(value) = value isa Pair ? column(first(value)) : value

# The category a group's value gives in a role: the value after the role's transformation, as in
# `:Chip => uppercase => "chip"`.
category(value, raw) = !(value isa Pair) ? raw :
    last(value) isa Function ? last(value)(raw) :
    last(value) isa Pair && first(last(value)) isa Function ? first(last(value))(raw) : raw

# The roles of `named` that divide the points of `columns` into groups: the categorical ones. A role
# of numbers, such as a continuous color, does not divide the points.
grouping(named::Vector, columns) =
    Pair{Symbol,Any}[role => value for (role, value) in named if !all(v -> v isa Number || ismissing(v), columns[column(value)])]

# Fit `curve` to the points of `table`, whose columns `positional` maps to x and y, once for each
# group of the categorical roles in `named`.
function fit_result(curve, starts::NamedTuple, table, positional::Vector, named::Vector; options...)::Result
    length(positional) == 2 || error("fit needs the points to map two positional values, x and y")
    columns = Tables.columntable(table)
    roles = grouping(named, columns)
    groups = fit_groups(curve, starts, columns, column.(positional)..., unique(Symbol[column(v) for (_, v) in roles]); options...)
    return Result(groups, positional, roles, :Lines)
end

# The result of fits already done, as `groups`, drawn as lines.
Result(::Fit, groups::Vector, positional::Vector, roles::Vector; scale=identity) =
    Result(groups, positional, roles, :Lines)
