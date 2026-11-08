# Probe: which parts of the computation graph Julia already tracks, in the compiler and in
# Serialization. Run: julia --startup-file=no work/computation-graph/compiler-structures.jl
# WIP: evidence for docs/plans/processing.md, not Core code.

using Serialization

struct Computed{F,Args<:Tuple}
    f::F
    args::Args
end
evaluate(x) = x
evaluate(c::Computed) = c.f(map(evaluate, c.args)...)

helper(x) = 2x
scaled(x) = helper(x) .+ 1
total(xs) = sum(xs)
c = Computed(total, (Computed(scaled, ([1.0, 2.0],)),))

# The compiled code of `evaluate` for this chain, and its validity range in world ages.
codeinstance(f, types) = Base.method_instance(f, types).cache
evaluate(c)
ci = codeinstance(evaluate, (typeof(c),))
println("1. evaluate(::typeof(c)) compiled; valid until world ", ci.max_world == typemax(UInt) ? "∞" : ci.max_world)

println("\n2. Methods it depends on, as the compiler recorded them (edges, transitively):")
function callees(ci, seen = Set{Any}())
    for e in ci.edges
        e isa Core.CodeInstance && (e = e.def)
        e isa Core.MethodInstance && !(e in seen) || continue
        push!(seen, e)
        e.cache isa Core.CodeInstance && callees(e.cache, seen)
    end
    return seen
end
for mi in callees(ci)
    mi.def.module === Main && println("   ", mi.specTypes)
end

println("\n3. Redefine `helper`, two calls away. The compiled chain is invalidated:")
@eval helper(x) = 3x
println("   valid until world ", ci.max_world, ", current world ", Base.get_world_counter())

println("\n4. Serialization stores an anonymous function with its code:")
path = tempname()
serialize(path, x -> x + 41)
out = read(`$(Base.julia_cmd()) --startup-file=no -e '
    using Serialization; f = deserialize(ARGS[1]); println("   in a new session: ", f(1), ", type ", typeof(f))' $path`, String)
print(out)
