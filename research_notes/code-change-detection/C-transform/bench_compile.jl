# Load and first-call time of the fit file, plain vs transformed, each in a fresh process.
# A warm-up on another small file first compiles CodeTrack itself, as a precompiled package would.
# Run: julia --startup-file=no --project=. bench_compile.jl
const SRC = joinpath(@__DIR__, "src", "CodeTrack.jl")
const FIT = joinpath(@__DIR__, "cases", "fit.jl")
child(mode) = """
include($(repr(SRC))); using .CodeTrack
module W end
write(joinpath(tempdir(), "ct_warm.jl"), "h(x) = g[1](x) .+ map(y -> y, x)\nconst g = Any[identity]\n")
Base.include(TrackCode(W), W, joinpath(tempdir(), "ct_warm.jl")); run_recorded(() -> W.h([1.0])); Base.include(W, joinpath(tempdir(), "ct_warm.jl"))
module U end
xs = collect(range(0, 5, length=1000)); ys = 2 .* exp.(-1.3 .* xs)
t_load = @elapsed $(mode == "plain" ? "Base.include(U, $(repr(FIT)))" : "Base.include(TrackCode(U), U, $(repr(FIT)))")
t_first = @elapsed $(mode == "plain" ? "" : "run_recorded(() -> ") (U.fit_elementwise(xs, ys, (1.5, 1.0, 0.0)), U.fit_vectorized(xs, ys, (1.5, 1.0, 0.0)), U.fit_forward(xs, ys, (1.5, 1.0, 0.0)))$(mode == "plain" ? "" : ")")
print(t_load, " ", t_first)
"""
for mode in ("plain", "tracked")
    runs = [parse.(Float64, split(read(`$(Base.julia_cmd()) --startup-file=no -e $(child(mode))`, String))) for _ in 1:3]
    best = minimum(r -> r[1] + r[2], runs)
    println(rpad(mode, 8), " load ", round(minimum(first, runs) * 1e3), " ms, first call ", round(minimum(last, runs) * 1e3), " ms (best of 3)")
end
