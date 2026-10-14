# User methods reached only through Base or a package. Run from the repo root:
#   julia --startup-file=no --project=bench research_notes/code-change-detection/R-review/r02_through_libraries.jl
include(joinpath(@__DIR__, "harness.jl"))

# a. Recipes: `read` builds a Sweep; `process` receives it as data and never names the type.
Core.eval(Main, quote
    struct Sweep; v::Vector{Float64}; end
    Base.iterate(s::Sweep, i=1) = i > length(s.v) ? nothing : (s.v[i], i + 1)
    Base.length(s::Sweep) = length(s.v)
    read_a = file -> Sweep([1.0, 2.0, 3.0])
    process_a = (data, _md) -> sum(data)
end)
for rule in (:exact, :supertypes, :library)
    Core.eval(Main, :(Base.iterate(s::Sweep, i=1) = i > length(s.v) ? nothing : (s.v[i], i + 1)))
    demo("a process gets a Sweep as data; iterate(::Sweep) edited", () -> process_a(read_a(""), nothing),
        () -> [process_a],
        :(Base.iterate(s::Sweep, i=1) = i > length(s.v) ? nothing : (2s.v[i], i + 1)); rule)
end
# The read stage's hash does change (it names Sweep). Its output is the same Sweep, so early
# cutoff (design.md, "Later") would then stop the rerun before it reaches process.
println("   read_a output before/after the edit is the same value: ",
    CodeRevisionFixed.deep_hash(nothing, read_a("")) == CodeRevisionFixed.deep_hash(nothing, read_a("")))

# b. Method added for an abstract supertype; the stage method names only the concrete type.
Core.eval(Main, quote
    abstract type AbstractCurve end
    struct IVCurve <: AbstractCurve; i::Vector{Float64}; end
    Base.iterate(c::AbstractCurve, k=1) = k > length(c.i) ? nothing : (c.i[k], k + 1)
    Base.length(c::AbstractCurve) = length(c.i)
    process_b(c::IVCurve) = sum(c)
end)
for rule in (:exact, :supertypes, :library)
    Core.eval(Main, :(Base.iterate(c::AbstractCurve, k=1) = k > length(c.i) ? nothing : (c.i[k], k + 1)))
    demo("b iterate(::AbstractCurve) edited, stage on IVCurve", () -> process_b(IVCurve([1.0, 2.0])),
        () -> [which(process_b, (IVCurve,))],
        :(Base.iterate(c::AbstractCurve, k=1) = k > length(c.i) ? nothing : (c.i[k] * 1e3, k + 1)); rule)
end

# c. Type piracy: a conversion that Base calls implicitly (push! into a Float64 vector).
Core.eval(Main, quote
    Base.convert(::Type{Float64}, s::AbstractString) = parse(Float64, s)
    process_c = (data, _md) -> (out = Float64[]; foreach(x -> push!(out, x), data); sum(out))
end)
for rule in (:exact, :supertypes, :library)
    Core.eval(Main, :(Base.convert(::Type{Float64}, s::AbstractString) = parse(Float64, s)))
    demo("c pirated convert(Float64, ::String) edited (mV -> V)", () -> process_c(["1", "2"], nothing),
        () -> [process_c], :(Base.convert(::Type{Float64}, s::AbstractString) = parse(Float64, s) / 1000); rule)
end

# d. `show` overload used by a label callback through string interpolation.
Core.eval(Main, quote
    struct Volt; x::Float64; end
    Base.show(io::IO, v::Volt) = print(io, v.x, " V")
    read_d = file -> (data = [1.0], metadata = Dict(:bias => Volt(1.5)))
    label_d = (_data, md) -> "IV at $(md[:bias])"
end)
for rule in (:exact, :supertypes, :library)
    Core.eval(Main, :(Base.show(io::IO, v::Volt) = print(io, v.x, " V")))
    demo("d show(::Volt) edited, label gets Volt inside metadata", () -> label_d(nothing, read_d("").metadata),
        () -> [label_d], :(Base.show(io::IO, v::Volt) = print(io, round(Int, 1000v.x), " mV")); rule)
end

# e. Makie recipe: plot!(::MyPlot) lives in Makie's method table; the draw callback names only
#    the generated `myplot!`.
using CairoMakie
Core.eval(Main, quote
    @recipe MyPlot (x,) begin end
    Makie.plot!(p::MyPlot) = lines!(p, p[1])
    draw_e = (ax, data) -> myplot!(ax, data)
    run_e() = (fig = Figure(); ax = Axis(fig[1, 1]); p = draw_e(ax, [1.0, 2.0, 3.0]); string(typeof(p.plots[1]).parameters[1]))
end)
for rule in (:exact, :supertypes, :library)
    Core.eval(Main, :(Makie.plot!(p::MyPlot) = lines!(p, p[1])))
    demo("e Makie recipe plot!(::MyPlot) edited (lines -> scatter)", run_e, () -> [draw_e],
        :(Makie.plot!(p::MyPlot) = scatter!(p, p[1])); rule)
end
