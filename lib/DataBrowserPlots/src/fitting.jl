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
