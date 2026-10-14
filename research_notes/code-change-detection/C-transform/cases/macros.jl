# Macros from Base, stdlibs and Makie inside user code.
using Printf, Logging
using GLMakie   # only to define a recipe and build a Figure in memory; nothing is displayed

scale(x) = 2x
const fs = Any[scale]

Base.@kwdef struct Settings
    gain::Float64 = scale(1.0)          # default value calls a user function
    f::Function = scale
end
kwdef_case(x) = Settings().f(x)
dot_case(xs) = @. fs[1](xs) + 1
threads_case(xs) = (out = similar(xs); Threads.@threads for i in eachindex(xs); out[i] = fs[1](xs[i]); end; out)
spawn_case(x) = fetch(Threads.@spawn fs[1](x))
views_case(xs) = @views sum(fs[1].(xs[1:2]))
inbounds_case(xs) = (s = 0.0; @inbounds @simd for i in eachindex(xs); s += scale(xs[i]); end; s)
printf_case(x) = @sprintf("%.1f", fs[1](x))
logging_case(x) = (with_logger(NullLogger()) do; @info "value" y = fs[1](x); end; scale(x))
assert_case(x) = (@assert fs[1](x) > 0 "positive"; x)
show_case(x) = (redirect_stdout(devnull) do; @show fs[1](x); end)
timed_case(x) = (@timed fs[1](x)).value
nospec_case(@nospecialize(x)) = fs[1](x)

@recipe ScaledLines (xs,) begin
    color = :black
end
function Makie.plot!(p::ScaledLines)
    lines!(p, map(xs -> fs[1].(xs), p[1]); color = p.color)
    return p
end
makie_case(xs) = (fig = Figure(); ax = Axis(fig[1, 1]); scaledlines!(ax, xs); fig)
