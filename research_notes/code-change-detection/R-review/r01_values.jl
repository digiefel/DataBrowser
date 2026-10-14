# Parameters held in values, not code. Run from the repo root:
#   julia --startup-file=no --project=bench research_notes/code-change-detection/R-review/r01_values.jl
include(joinpath(@__DIR__, "harness.jl"))

# a. Tunable threshold in a const Ref (common Julia idiom). No world change on `[]=`.
Core.eval(Main, quote
    const THRESH = Ref(0.5)
    stage_a(v) = count(>(THRESH[]), v)
end)
demo("a const Ref mutated: THRESH[] = 0.9", () -> stage_a([0.6, 0.7, 1.0]), () -> [stage_a],
    :(THRESH[] = 0.9))

# b. Parameters in a user struct, const redefined in the REPL. World moves; the value is not
#    "plain", so the prototype does not hash it.
Core.eval(Main, quote
    Base.@kwdef struct FitParams; gain::Float64 = 2.0; order::Int = 1; end
    const PARAMS = FitParams()
    stage_b(x) = PARAMS.gain * x
end)
demo("b const struct of parameters redefined", () -> stage_b(1.0), () -> [stage_b],
    :(const PARAMS = FitParams(gain=3.0)))

# c. @kwdef default edited (Revise re-evaluates the struct); the stage builds FitParams() itself.
Core.eval(Main, quote
    Base.@kwdef struct KwP; gain::Float64 = 2.0; end
    stage_c(x) = KwP().gain * x
end)
demo("c @kwdef default edited", () -> stage_c(1.0), () -> [stage_c],
    :(Base.@kwdef struct KwP; gain::Float64 = 5.0; end))

# d. A NamedTuple of parameters with a model function, captured by a callback made from a script.
Core.eval(Main, quote
    gauss(x, p) = p[1] * exp(-x^2)
    make_process(params) = data -> params.model(data, params.p0)
    const cb_d = make_process((model = gauss, p0 = [2.0]))
end)
demo("d function inside a captured NamedTuple, edited", () -> cb_d(0.0), () -> [cb_d],
    :(gauss(x, p) = p[1] * exp(-x^2) + 1))

# e. Options struct captured by a callback, then mutated in the REPL (no world change).
Core.eval(Main, quote
    mutable struct Opts; maxiter::Int; end
    const OPTS = Opts(5)
    const cb_e = let o = OPTS; data -> min(data, o.maxiter); end
end)
demo("e captured mutable options mutated (o.maxiter = 2)", () -> cb_e(10), () -> [cb_e],
    :(OPTS.maxiter = 2))

# f. Calibration table loaded into a const from a file (> 10_000 values), then reloaded.
Core.eval(Main, quote
    const CAL = collect(range(0, 1; length=20_000))
    stage_f(i) = CAL[i]
end)
demo("f const array > 10_000 values redefined", () -> stage_f(2), () -> [stage_f],
    :(const CAL = collect(range(0, 2; length=20_000))))

# g. Lookup Dict filled by a script after the workspace opened (push! / setindex!, no world change).
Core.eval(Main, quote
    const DEVICE_AREA = Dict{String,Float64}("A1" => 1.0)
    stage_g(dev) = get(DEVICE_AREA, dev, NaN)
end)
demo("g const Dict filled later (DEVICE_AREA[\"B2\"] = 4.0)", () -> stage_g("B2"), () -> [stage_g],
    :(DEVICE_AREA["B2"] = 4.0))
