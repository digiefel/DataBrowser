# Mechanism 1a: what the compiler records after `process` has run.
# Walk the CodeInstance edges of `process` transitively and list the user methods reached.
# Run: julia --startup-file=no 01_backedges.jl
include("testproject.jl"); using .UserProject: UserProject as U

item = U.make_item()
U.process(item)

# Methods of UserProject reached by following `ci.edges` from every compiled specialization of `root`.
function edge_closure(root::Method)
    seen = Set{Method}(); todo = Any[root]
    while !isempty(todo)
        m = pop!(todo)
        m isa Method || continue
        m in seen && continue
        push!(seen, m)
        for mi in Base.specializations(m)
            isdefined(mi, :cache) || continue
            ci = mi.cache
            while ci !== nothing
                for e in ci.edges
                    # edges hold CodeInstances, MethodInstances, Methods, or call signatures
                    e isa Core.CodeInstance && (e = e.def)
                    e isa Core.MethodInstance && push!(todo, e.def)
                    e isa Method && push!(todo, e)
                end
                ci = isdefined(ci, :next) ? ci.next : nothing
            end
        end
    end
    return seen
end

reached = edge_closure(only(methods(U.process)))
user = sort([string(m.name) for m in reached if m.module === U])
println("user methods reached by compiler edges: ", user)
println("missing (expected but not reached):   ",
        [n for n in U.EXPECTED if !any(u -> occursin(string(n), u), user)])
println("total methods reached (all modules):   ", length(reached))

# Does the edge set see the dynamic call? Redefine gn_step's helper and check invalidation.
w = Base.get_world_counter()
kwbody = getproperty(U, only(filter(n -> startswith(string(n), "#fit#"), names(U; all = true))))
ci_fit = only(Base.specializations(only(methods(kwbody)))).cache
@eval U jacrow(p, x) = (exp(-p[2] * x), -p[1] * x * exp(-p[2] * x), 1.0 + 0.0)
println("after redefining jacrow: fit body still valid? ", ci_fit.max_world == typemax(UInt))
