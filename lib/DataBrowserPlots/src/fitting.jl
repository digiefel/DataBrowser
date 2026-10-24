# TODO: move fitting to DataBrowserFitting, with a REPL API and results kept by the workspace
# (plans/fitting.md).

"""
A fitted parameter: its estimate `value` and one standard `error`. It prints as `1520 ± 83`.
"""
struct Parameter
    value::Float64
    error::Float64
end

function Base.show(io::IO, parameter::Parameter)
    value, error = parameter.value, parameter.error
    # Two significant digits of the error, and the estimate to the same place.
    # TODO: the rounding of estimates and errors is not decided (plans/fitting.md).
    isfinite(error) && error > 0 || return print(io, round(value; sigdigits=4), " ± ", error)
    digits = 1 - floor(Int, log10(error))
    shown(x) = digits > 0 ? string(round(x; digits)) : string(round(Int, round(x; digits)))
    print(io, shown(value), " ± ", shown(error))
end

# The least-squares estimates of the parameters named in `starts`, each with one standard error
# from the covariance, scaled by the residuals.
# TODO: known errors, weights, bounds and fixed parameters (plans/fitting.md).
function solve_fit(curve, x::Vector{Float64}, y::Vector{Float64}, starts::NamedTuple)::NamedTuple
    names = keys(starts)
    residual(p, _) = curve.(x; NamedTuple{names}(Tuple(p))...) .- y
    problem = NonlinearLeastSquaresProblem(residual, collect(Float64, values(starts)))
    solution = solve(problem, LevenbergMarquardt())
    SciMLBase.successful_retcode(solution) || error("the fit did not converge ($(solution.retcode))")
    free = length(x) - length(names)
    free > 0 || error("$(length(x)) points cannot fit $(length(names)) parameters")
    J = ForwardDiff.jacobian(p -> residual(p, nothing), solution.u)
    covariance = inv(J' * J) * sum(abs2, solution.resid) / free
    errors = sqrt.(max.(diag(covariance), 0.0))
    return NamedTuple{names}(Tuple(Parameter.(solution.u, errors)))
end

# One fit for each group of `rows`, a Tables.jl table: the rows with equal values in the `group`
# columns. Each fit is a `Group`: its metadata holds the group's values and the parameters, its data
# is the curve, as columns `x` and `y`, and its members are the items whose rows it fits. `members`
# are those items, and the column `item` holds each row's item id.
# The curve is drawn over the fitted x values, or over `xlim`.
function fit_groups(curve, starts::NamedTuple, rows, x::Symbol, y::Symbol, group::Vector{Symbol};
        members=AbstractDataItem[], item=nothing, xlim=nothing)::Vector{Group}
    table = Tables.columntable(rows)
    keys = [NamedTuple{Tuple(group)}(Tuple(table[g][row] for g in group)) for row in eachindex(table[x])]
    return map(unique(keys)) do key
        rows = [row for row in eachindex(keys) if keys[row] == key &&
            table[x][row] isa Real && table[y][row] isa Real && isfinite(table[x][row]) && isfinite(table[y][row])]
        xs, ys = Float64.(table[x][rows]), Float64.(table[y][rows])
        name = string(nameof(curve), isempty(key) ? "" : " for " * join(("$k = $v" for (k, v) in pairs(key)), ", "))
        parameters = try
            solve_fit(curve, xs, ys, starts)
        catch err
            error("Fitting $name: $(sprint(showerror, err))")
        end
        low, high = xlim === nothing ? extrema(xs) : xlim
        curve_x = collect(range(low, high; length=100))
        curve_y = curve.(curve_x; map(parameter -> parameter.value, parameters)...)
        fitted = item === nothing ? AbstractDataItem[] : AbstractDataItem[m for m in members if id(m) in table[item][rows]]
        return Group(name, Dict{Symbol,Any}(pairs(key)..., pairs(parameters)...), (x=curve_x, y=curve_y), fitted)
    end
end

"""
What a line of [`@plot`](@ref) computes from its points, such as the curves and parameters of
`fit`: one `Group` for each group of points. It is a vector of those groups.

Multiply it by a `visual` to draw it: its data is drawn on the axes of the points, in the named
roles of their groups, such as `color`, so that it shares their legend entries. Alone, it is drawn
with its own visual, `Lines` for a fit.
"""
struct Result <: AbstractVector{Group}
    groups::Vector{Group}
    # The values the points mapped to x and y, as `mapping` takes them, such as `:gap => "gap (µm)"`.
    positional::Vector{Any}
    # The named roles that form the groups, such as `:color => :Chip`.
    named::Vector{Pair{Symbol,Any}}
    # The plot type it is drawn with when no visual is given, a name in Makie.
    plottype::Symbol
end
Base.size(result::Result) = size(result.groups)
Base.getindex(result::Result, index::Int) = result.groups[index]

"""
A curve to fit to the points of a layer, as `fit(curve, starts; options...)` in [`@plot`](@ref)
writes it. The fit is done when the layer has its points, and gives a [`Result`](@ref).
"""
struct Fit
    curve::Any
    starts::NamedTuple
    options::NamedTuple
end
Fit(curve, starts::NamedTuple; options...) = Fit(curve, starts, NamedTuple(options))

# The column of a layer's table that holds the id of each row's item.
const ITEM = Symbol("#item")

# The `ITEM` column of the tables of the items of a selection, as keywords of `unnest`.
item_ids(selection::Selection) = NamedTuple{(ITEM,)}((selection.id,))
item_ids(_) = (;)

# The fit's result over the points of a layer: `table`, whose columns `positional` and `named`
# map. Its groups' members are the items of `source` whose rows they fit.
function fit_result(fit::Fit, table, positional::Vector, named::Vector, source)::Result
    columns = Tables.columntable(table)
    members = haskey(columns, ITEM) ? (; members=Workspace.items(source), item=ITEM) : (;)
    return fit_result(fit.curve, fit.starts, columns, positional, named; members..., fit.options...)
end

# The column a value of `mapping` names: `:R` in `:R`, in `:R => "R (Ω)"` and in `:R => f => "R"`.
column(value) = value isa Pair ? column(first(value)) : value

# The category a group's value gives in a role: the value after the role's transformation, as in
# `:Chip => uppercase => "chip"`.
category(value, raw) = !(value isa Pair) ? raw :
    last(value) isa Function ? last(value)(raw) :
    last(value) isa Pair && first(last(value)) isa Function ? first(last(value))(raw) : raw

# Fit `curve` to the points of `table`, whose columns `positional` maps to x and y, once for each
# group of the categorical roles in `named`. A role of numbers, such as a continuous color, does
# not divide the points.
function fit_result(curve, starts::NamedTuple, table, positional::Vector, named::Vector; options...)::Result
    length(positional) == 2 || error("fit needs the points to map two positional values, x and y")
    columns = Tables.columntable(table)
    # TODO: a role given as a formula, such as `color=chip(:folder)`, keeps its group's value
    # under the formula's text, so a label reads it as `:var"chip(:folder)"`.
    roles = [role => value for (role, value) in named if !all(v -> v isa Number || ismissing(v), columns[column(value)])]
    groups = fit_groups(curve, starts, columns, column.(positional)..., unique(Symbol[column(v) for (_, v) in roles]); options...)
    return Result(groups, positional, roles, :Lines)
end
