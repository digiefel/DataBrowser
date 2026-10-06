"""Count with a pluralized noun, e.g. `1 plot`, `3 plots`."""
_plural(n::Integer, word::AbstractString)::String = "$n $word" * (n == 1 ? "" : "s")

Base.show(io::IO, project::Project) =
    print(io, "Project(\"$(project.name)\", ", _plural(length(project.recipes), "item kind"), ")")

function Base.show(io::IO, ::MIME"text/plain", project::Project)
    print(io, "Project \"$(project.name)\"")
    isempty(project.description) || print(io, " · ", project.description)

    print(io, "\n  ", _plural(length(project.recipes), "item kind"))
    isempty(project.recipes) || print(io, " (detection order):")
    pad = isempty(project.recipes) ? 0 : maximum(length(string(r.kind)) for r in project.recipes)
    for recipe in project.recipes
        optional = [name for (name, f) in
            (("expand", recipe.expand), ("process", recipe.process),
             ("analyze", recipe.analyze), ("label", recipe.label),
             ("collection", recipe.collection), ("id", recipe.id))
            if f !== nothing]
        steps = isempty(optional) ? "" : " · " * join(optional, " · ")
        print(io, "\n    ", rstrip(rpad(string(recipe.kind), pad) * steps))
    end

    print(io, "\n  ", _plural(length(project.collections), "collection recipe"))
    isempty(project.collections) || print(io, ":")
    for recipe in values(project.collections)
        stages = [name for (name, f) in
            (("process", recipe.process), ("analyze", recipe.analyze)) if f !== nothing]
        print(io, "\n    ", recipe.kind, " · ", join(stages, " · "))
    end
end

"""Create an empty project. Register item and collection recipes into it afterwards."""
function define_project(name::AbstractString; description::AbstractString="")::Project
    return Project(
        String(name),
        String(description),
        ItemRecipe[],
        Dict{Symbol,CollectionRecipe}(),
    )
end

const UNNAMED_ITEM_REGISTRATION = Symbol("#unnamed")

"""
    register_item!(project, [kind]; read, callbacks...) -> project

Register or replace one item pipeline. `read` is the only required callback. Registration
callbacks receive ordinary project data and metadata dictionaries; DataBrowser owns item identity
and storage records internally.

`collection(data, metadata)` places the item in the collection tree. It returns a named tuple that
names each level from the top down, such as `(wafer = metadata[:wafer], device = metadata[:device])`.
Without it, the item goes where its source item is: for a directory source, the file's directories.

`label(data, metadata)` runs when the item is created, and again after `process` and after
`analyze` with the metadata those stages added, so a label can show analysis results once they
exist.

Calling the unnamed form again replaces the project's unnamed registration. Calling the named form
again with the same name replaces that registration in place.
"""
function register_item!(
    project::Project,
    kind::Symbol;
    read,
    detect=Returns(true),
    expand=nothing,
    process=nothing,
    analyze=nothing,
    label=nothing,
    collection=nothing,
    id=nothing,
)::Project
    recipe = ItemRecipe(
        kind, detect, read, expand, process, analyze, label, collection, id)
    index = findfirst(r -> r.kind === kind, project.recipes)
    index === nothing ? push!(project.recipes, recipe) : (project.recipes[index] = recipe)
    return project
end

function register_item!(project::Project; kwargs...)::Project
    return register_item!(project, UNNAMED_ITEM_REGISTRATION; kwargs...)
end

"""
Register (or replace) the collection recipe for one item kind.

`process(data, metadata)` receives aligned vectors and returns one data value per input.
`analyze(data, metadata)` receives the processed values and returns metadata for the collection.
Re-calling with the same registration name replaces the recipe.
"""
function register_collection_analysis!(
    project::Project,
    kind::Symbol;
    process=nothing,
    analyze=nothing,
)::Project
    project.collections[kind] = CollectionRecipe(kind, process, analyze)
    return project
end
