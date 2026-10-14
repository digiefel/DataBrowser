# Cost of a full recompute on the user's RuO2 project (read only: nothing is written there).
# Run: julia --startup-file=no --project=bench research_notes/code-change-detection/A-static-walk/cost_ruo2.jl
#
# Loads browser.jl up to (not including) `open_workspace`, so no workspace, cache or window opens.

const PROJECT_DIR = "/Users/davide/work/phd/Borg/202501_RuO2test/analysis/electrical v2"
const BROWSER = joinpath(PROJECT_DIR, "browser.jl")

src = read(BROWSER, String)
src = src[1:findfirst("ws = open_workspace", src).start-1]
# Relative `include`s inside browser.jl resolve against this path.
task_local_storage(:SOURCE_PATH, BROWSER) do
    include_string(Main, src, BROWSER)
end

include(joinpath(@__DIR__, "CodeRevision.jl"))
using .CodeRevision

const STAGES = (:detect, :read, :expand, :id, :label, :collection, :process, :analyze)
roots = [(Symbol(r.kind, '.', s), getfield(r, s)) for r in PROJECT.recipes for s in STAGES
         if getfield(r, s) !== nothing]
println(length(PROJECT.recipes), " recipes, ", length(roots), " stage roots")

function per_stage(exclude)
    [(name, code_revision([f]; exclude)) for (name, f) in roots]
end

# A real recheck happens after the world counter moved, so the method-list cache is cold.
bump!() = Core.eval(Main, :(_world_bump() = $(rand())))

for (label, exclude) in (("DataBrowser as library", LIBRARY_MODULES),
                         ("DataBrowser packages walked too (dev)", [:CodeRevision]))
    per_stage(exclude); code_revision(last.(roots); exclude)  # compile
    bump!(); t = @elapsed reports = per_stage(exclude)
    t_warm = @elapsed per_stage(exclude)
    bump!(); t_all = @elapsed all = code_revision(last.(roots); exclude)
    println("\n== ", label)
    println("one walk per stage root, after a world change: ", round(1000t; digits=1),
        " ms (again in the same world: ", round(1000t_warm; digits=1), " ms); methods per root: median ",
        sort([r.methods for (_, r) in reports])[cld(end, 2)], ", max ", maximum(r.methods for (_, r) in reports))
    println("one combined walk, after a world change: ", round(1000t_all; digits=1), " ms; ", all.methods,
        " methods, ", all.types, " types, ", all.values, " values, ", all.functions, " functions scanned")
    println("non-const globals read: ", all.nonconst_globals)
    println("unhashed values:        ", first(all.unhashed, 8), length(all.unhashed) > 8 ? " ..." : "")
    if exclude == LIBRARY_MODULES
        for (name, r) in reports
            println("  ", rpad(name, 26), r.hash[1:8], "  ", r.methods, " methods")
        end
    end
end
