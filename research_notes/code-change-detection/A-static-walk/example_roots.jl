# Stage roots and hashes for the example projects, loaded without opening a workspace.
# Run: julia --startup-file=no --project=bench research_notes/code-change-detection/A-static-walk/example_roots.jl
#
# Note: examples/04_domain_project is a Recipes project (it calls `register_item!`); the type-API
# example is examples/03_typed_micrographs.

using DataBrowser
include(joinpath(@__DIR__, "CodeRevision.jl"))
using .CodeRevision

const EXAMPLES = normpath(joinpath(@__DIR__, "..", "..", "..", "examples"))
const RECIPE_STAGES = (:detect, :read, :expand, :id, :label, :collection, :process, :analyze)

show_root(name, roots) = (r = code_revision(roots; exclude=LIBRARY_MODULES);
    println(rpad(name, 34), r.hash[1:10], "  ", r.methods, " methods, ", r.types, " types, ",
        r.values, " values", isempty(r.unhashed) ? "" : "  unhashed: $(r.unhashed)"))

"""Recipes roots: the callbacks stored in the project, one root set per stage."""
function recipe_roots(project)
    for recipe in project.recipes, stage in RECIPE_STAGES
        f = getfield(recipe, stage)
        f === nothing || show_root("$(recipe.kind).$stage", [f])
    end
    for (kind, recipe) in project.collections, stage in (:process, :analyze)
        f = getfield(recipe, stage)
        f === nothing || show_root("collection $(kind).$stage", [f])
    end
end

println("== 01_simple_csv (Recipes, premade register_csv!)")
csv_project = define_project("CSV tables")
register_csv!(csv_project)
recipe_roots(csv_project)

println("\n== 04_domain_project (Recipes)")
include(joinpath(EXAMPLES, "04_domain_project", "FerroelectricProject.jl"))
recipe_roots(FerroelectricProject.define_ferroelectric_project())

println("\n== 03_typed_micrographs (type API)")
# Evaluate the script up to the point where it builds the project; skip ARGS and the workspace.
src = read(joinpath(EXAMPLES, "03_typed_micrographs", "project.jl"), String)
src = replace(src[1:findfirst("project = MicrographProject()", src).start-1],
    r"length\(ARGS\).*\n" => "")
include_string(Main, src, "03_typed_micrographs/project.jl")
P, S, I = MicrographProject, MicrographDirectory, MicrographFile
show_root("read", [which(DataBrowser.read, (P, S, I))])
show_root("expand", [which(DataBrowser.expand, (P, I, Micrograph))])
show_root("process", [which(DataBrowser.process, (P, Micrograph))])
show_root("analyze", [which(DataBrowser.analyze, (P, Micrograph))])
