# The design's fixes on the user's RuO2 project (read only). Run from the repo root:
#   julia --startup-file=no --project=bench research_notes/code-change-detection/R-review/r05_ruo2.jl
# Loads browser.jl up to `open_workspace`, like A-static-walk/cost_ruo2.jl.
const PROJECT_DIR = "/Users/davide/work/phd/Borg/202501_RuO2test/analysis/electrical v2"
const BROWSER = joinpath(PROJECT_DIR, "browser.jl")
src = read(BROWSER, String)
src = src[1:findfirst("ws = open_workspace", src).start-1]
task_local_storage(:SOURCE_PATH, BROWSER) do
    include_string(Main, src, BROWSER)
end
include(joinpath(@__DIR__, "harness.jl"))

const STAGES = (:detect, :read, :expand, :id, :label, :collection, :process, :analyze)
roots = [(string(r.kind, '.', s), getfield(r, s)) for r in PROJECT.recipes for s in STAGES
         if getfield(r, s) !== nothing]
bump!() = Core.eval(Main, :(_world_bump() = $(rand())))

for rule in (:none, :exact, :supertypes)
    walk() = [(n, CodeRevisionFixed.code_revision([f]; exclude=EXCL, type_rule=rule)) for (n, f) in roots]
    walk(); bump!()
    t = @elapsed reports = walk()
    tp = @elapsed foreach(r -> poll_hash(last(r)), reports)
    nm = sort([length(r.roots_seen) for (_, r) in reports])
    # How many stage roots each method is part of: the rerun fan-out of a one-line edit.
    fan = Dict{Method,Int}()
    for (_, r) in reports, m in unique(r.roots_seen)
        fan[m] = get(fan, m, 0) + 1
    end
    top = sort(collect(fan); by=last, rev=true)
    println("\n== type_rule = $rule: walk ", round(1000t; digits=1), " ms, one poll of all stages ",
        round(1000tp; digits=2), " ms; methods per stage median ", nm[cld(end, 2)], ", max ", nm[end])
    println("   stages per method: median ", sort(collect(values(fan)))[cld(end, 2)], " of ", length(roots),
        "; top: ", join(["$(m.name)=$(c)" for (m, c) in first(top, 6)], ", "))
    rule === :exact && println("   polled per stage (max): ", maximum(length(r.polled) for (_, r) in reports),
        "; labels: ", join(unique(first.(vcat([r.polled for (_, r) in reports]...))), ", "))
    rule === :exact && println("   unhashed: ", unique(vcat([r.unhashed for (_, r) in reports]...)))
end
