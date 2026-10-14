# Mechanism 4: find the dynamic call sites without running the stage.
# Infer `process` with `code_typed`, follow every statically resolved call (`:invoke`), and list
# the calls left for run-time dispatch. Those sites are exactly where compiler edges stop.
# Run: julia --startup-file=no 06_dynamic_sites.jl
include("testproject.jl"); using .UserProject: UserProject as U

isbuiltin(f) = f isa Core.Builtin || f isa Core.IntrinsicFunction

function dynamic_sites(f, argtypes)
    sites = Tuple{Method, Any}[]; seen = Set{Core.MethodInstance}(); todo = Any[(f, argtypes)]
    visited = 0
    while !isempty(todo)
        g, ats = pop!(todo)
        for (ci, _) in code_typed(g, ats; optimize = true)
            mi = ci.parent; mi in seen && continue; push!(seen, mi); visited += 1
            for stmt in ci.code
                stmt isa Expr || continue
                if stmt.head === :invoke
                    target = stmt.args[1]
                    target isa Core.CodeInstance && (target = target.def)
                    tt = target.specTypes.parameters
                    callee = tt[1]
                    callee <: Function && isdefined(callee, :instance) || continue  # skip closures etc. for brevity
                    push!(todo, (callee.instance, Tuple{tt[2:end]...}))
                elseif stmt.head === :call
                    callee = stmt.args[1]
                    callee isa GlobalRef && (callee = getglobal(callee.mod, callee.name))
                    isbuiltin(callee) || push!(sites, (mi.def, stmt))
                end
            end
        end
    end
    return sites, visited
end

item = U.make_item(10)
sites, visited = dynamic_sites(U.process, Tuple{typeof(item)})
println("specializations inferred: ", visited, ";  dynamic call sites: ", length(sites))
for (m, s) in sites
    m.module === U && println("  in ", m.name, ": ", s)
end
