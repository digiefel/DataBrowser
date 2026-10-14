# Cost of the code check in DataBrowserCore on the user's RuO2 project (read only: nothing is
# written there). Run: julia --startup-file=no --project=bench research_notes/code-change-detection/cost_core_ruo2.jl
#
# Loads browser.jl up to (not including) `open_workspace`, so no workspace, cache or window opens.

const PROJECT_DIR = "/Users/davide/work/phd/Borg/202501_RuO2test/analysis/electrical v2"
const BROWSER = joinpath(PROJECT_DIR, "browser.jl")
src = read(BROWSER, String)
src = src[1:findfirst("ws = open_workspace", src).start-1]
task_local_storage(:SOURCE_PATH, BROWSER) do
    include_string(Main, src, BROWSER)
end

using DataBrowserAPI: stage_roots, SOURCE_READ, ITEM_PROCESS, ITEM_ANALYZE
using DataBrowserCore.CodeRevisions: code_revision
using DataBrowserSources: SourceFile
using DataBrowserRecipes: RegisteredDataItem

# What a workspace records: reading for the source item type, and processing and analysis for each kind.
targets = [(SOURCE_READ, SourceFile);
    [(stage, RegisteredDataItem{recipe.kind}) for recipe in PROJECT.recipes for stage in (ITEM_PROCESS, ITEM_ANALYZE)]]
revisions() = [code_revision(stage_roots(PROJECT, target...)) for target in targets]
bump!() = Core.eval(Main, :(_world_bump() = $(rand())))

revisions()  # compile
bump!(); cold = @elapsed first_revisions = revisions()
warm = @elapsed revisions()
bump!(); again = revisions()
println(length(targets), " stage targets; all revisions after a definition: ", round(1000cold; digits=1),
    " ms; again in the same world: ", round(1000warm; digits=1), " ms")
println("parts per target: ", [length(r.parts) for r in first_revisions])
println("unchanged by an unrelated definition: ", all(a.hash == b.hash for (a, b) in zip(first_revisions, again)))
println("not tracked: ", unique(reduce(vcat, [r.untracked for r in first_revisions])))
