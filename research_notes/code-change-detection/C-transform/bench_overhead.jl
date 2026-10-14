# Run-time overhead of the transform on a curve fit over 1e5 points.
# Run: julia --startup-file=no --project=. bench_overhead.jl
using BenchmarkTools
include("src/CodeTrack.jl"); using .CodeTrack

module Plain end;        Base.include(Plain, joinpath(@__DIR__, "cases", "fit.jl"))
module Tracked end;      Base.include(TrackCode(Tracked), Tracked, joinpath(@__DIR__, "cases", "fit.jl"))
module TrackedSites end; Base.include(TrackCode(TrackedSites; sites=true), TrackedSites, joinpath(@__DIR__, "cases", "fit.jl"))

xs = collect(range(0, 5, length=100_000)); ys = 2 .* exp.(-1.3 .* xs) .+ 0.5 .+ 0.01 .* randn(length(xs))
p0 = (1.5, 1.0, 0.0)
@assert Plain.fit_elementwise(xs, ys, p0) ≈ Tracked.fit_elementwise(xs, ys, p0)

ms(t) = round(t * 1e3, digits=2)
println(rpad("function", 18), rpad("plain", 10), rpad("tracked,idle", 14), rpad("tracked,rec", 13), "sites,rec   (ms)")
for f in (:fit_elementwise, :fit_vectorized, :fit_forward)
    plain = @belapsed $(getglobal(Plain, f))($xs, $ys, $p0)
    idle  = @belapsed $(getglobal(Tracked, f))($xs, $ys, $p0)
    rec   = @belapsed run_recorded(() -> $(getglobal(Tracked, f))($xs, $ys, $p0))
    sites = @belapsed run_recorded(() -> $(getglobal(TrackedSites, f))($xs, $ys, $p0))
    println(rpad(f, 18), rpad(ms(plain), 10), rpad(ms(idle), 14), rpad(ms(rec), 13), ms(sites))
end
r = run_recorded(() -> Tracked.fit_elementwise(xs, ys, p0))[2]
println("\nsignatures recorded by one fit_elementwise run: ", length(r.sigs))
foreach(s -> println("  ", s), r.sigs)
