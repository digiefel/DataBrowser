"""
The least-squares solver behind `fit` in DataBrowserPlots.

DataBrowserPlots loads this package on the first fit of a session, so that a session without fits
does not load NonlinearSolve and ForwardDiff.
"""
module DataBrowserFitting

import ForwardDiff
using LinearAlgebra: diag
using NonlinearSolve: LevenbergMarquardt, NonlinearLeastSquaresProblem, SciMLBase, solve

# TODO: the fitting API of plans/fitting.md, connected to Core.

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

end
