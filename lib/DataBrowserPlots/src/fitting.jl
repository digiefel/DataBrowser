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

"""
The fit of a curve to one group of the points of a plot, as a named `fit` line of [`@plot`](@ref)
gives it. A property is a parameter of the curve, such as `contacts.Rc`, a [`Parameter`](@ref)
with its error; or a value that the group shares, such as `contacts.Chip`; or `x` and `y`, the
drawn curve.
"""
struct Fit
    parameters::NamedTuple
    # The value of each named role of the plot, such as `(Chip = "72b",)`.
    group::NamedTuple
    x::Vector{Float64}
    y::Vector{Float64}
end

function Base.getproperty(fit::Fit, name::Symbol)
    # TODO: a parameter, a group value and `x` or `y` may share a name (plans/fitting.md).
    parameters, group = getfield(fit, :parameters), getfield(fit, :group)
    haskey(parameters, name) && return parameters[name]
    haskey(group, name) && return group[name]
    name in (:x, :y) && return getfield(fit, name)
    error("The fit has no `$name`; it has `$(join(propertynames(fit), "`, `"))`")
end
Base.propertynames(fit::Fit) = (keys(getfield(fit, :parameters))..., keys(getfield(fit, :group))..., :x, :y)

function Base.show(io::IO, fit::Fit)
    group = getfield(fit, :group)
    print(io, "Fit")
    isempty(group) || print(io, " for ", join(("$k = $v" for (k, v) in pairs(group)), ", "))
    print(io, ": ", join(("$k = $v" for (k, v) in pairs(getfield(fit, :parameters))), ", "))
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
# columns.
# The curve is drawn over the fitted x values, or over `xlim`.
function fit_groups(curve, starts::NamedTuple, rows, x::Symbol, y::Symbol,
        group::Vector{Symbol}; xlim=nothing)::Vector{Fit}
    table = Tables.columntable(rows)
    keys = [NamedTuple{Tuple(group)}(Tuple(table[g][row] for g in group)) for row in eachindex(table[x])]
    return map(unique(keys)) do key
        rows = [row for row in eachindex(keys) if keys[row] == key &&
            table[x][row] isa Real && table[y][row] isa Real && isfinite(table[x][row]) && isfinite(table[y][row])]
        xs, ys = Float64.(table[x][rows]), Float64.(table[y][rows])
        parameters = try
            solve_fit(curve, xs, ys, starts)
        catch err
            error("Fitting $(nameof(curve)) to the points" * (isempty(key) ? "" : " of $key") *
                  ": $(sprint(showerror, err))")
        end
        low, high = xlim === nothing ? extrema(xs) : xlim
        curve_x = collect(range(low, high; length=100))
        curve_y = curve.(curve_x; map(parameter -> parameter.value, parameters)...)
        return Fit(parameters, key, curve_x, curve_y)
    end
end
