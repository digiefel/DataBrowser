# Probe: how compile time and inference grow with the depth of a chain of Computed values, each
# step a different function, as a GUI chain of transforms would be.
# Run: julia --startup-file=no work/computation-graph/lazy-depth.jl
struct Computed{F,Args<:Tuple,S<:NamedTuple}
    f::F
    args::Args
    settings::S
end
Computed(f, args...; settings...) = Computed(f, args, NamedTuple(settings))
evaluate(x) = x
evaluate(c::Computed) = c.f(map(evaluate, c.args)...; c.settings...)

# Warm the shared code on a chain of one step.
evaluate(Computed(identity, [1.0, 2.0]))
for depth in (1, 5, 10, 20, 40, 80)
    # New functions for each depth, so nothing compiled earlier is reused.
    steps = [Core.eval(Main, :(x -> x .+ $depth .* $k)) for k in 1:depth]
    chain = Base.invokelatest() do
        c = [1.0, 2.0]
        for f in steps
            c = Computed(f, c)
        end
        c
    end
    infer = @elapsed T = Base.invokelatest(Base.infer_return_type, evaluate, (typeof(chain),))
    first = @elapsed Base.invokelatest(evaluate, chain)
    again = @elapsed Base.invokelatest(evaluate, chain)
    println(lpad(depth, 3), " steps: infer ", lpad(round(1000infer; digits = 1), 7), " ms (", T,
        "), first run ", lpad(round(1000first; digits = 1), 7), " ms, again ", round(1e6again; digits = 1), " µs")
end

# The same new functions applied directly, without Computed: the part of the cost any approach pays.
println("without Computed:")
for depth in (1, 5, 10, 20, 40, 80)
    steps = [Core.eval(Main, :(x -> x .+ $(depth + 1000) .* $k)) for k in 1:depth]
    first = @elapsed Base.invokelatest() do
        x = [1.0, 2.0]
        for f in steps
            x = f(x)
        end
        x
    end
    println(lpad(depth, 3), " steps: first run ", lpad(round(1000first; digits = 1), 7), " ms")
end
