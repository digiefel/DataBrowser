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
    for recipe in project.collections
        callbacks = [name for (name, f) in (("process", recipe.process), ("analyze", recipe.analyze)) if f !== nothing]
        members = recipe.members === nothing ? "" : " ($(recipe.members))"
        print(io, "\n    ", recipe.level, members, " · ", join(callbacks, " · "))
    end
end

"""Create an empty project. Register item and collection recipes into it afterwards."""
function define_project(name::AbstractString; description::AbstractString="")::Project
    return Project(
        String(name),
        String(description),
        ItemRecipe[],
        CollectionRecipe[],
    )
end

const UNNAMED_ITEM_REGISTRATION = Symbol("#unnamed")

"""
    register_item!(project, [kind]; read, callbacks...) -> project

Register or replace one item pipeline. `read` is the only required callback. Registration
callbacks receive ordinary project data and metadata dictionaries; DataBrowser owns item identity
and storage records internally.

Returned metadata may be a dictionary, named tuple, single pair, or any iterable accepted
by `Dict`. Keys are converted to symbols and values must be supported metadata values.

`collection(data, metadata)` places the item in the collection tree. It returns a named tuple that
names each level from the top down, such as `(wafer = metadata[:wafer], device = metadata[:device])`.
Without it, the item goes where its source item is: for a directory source, the file's directories.

`analyze(data, metadata)` runs right after `process` on the processed data, and returns metadata
that the processed item gets.

`label(data, metadata)` runs when the item is created, and again after `process` and `analyze` with
the metadata they added, so a label can show analysis results once they exist.

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
        kind, detect, read, expand, process, analyze, label, collection, id, caller())
    index = findfirst(r -> r.kind === kind, project.recipes)
    index === nothing ? push!(project.recipes, recipe) : (project.recipes[index] = recipe)
    return project
end

function register_item!(project::Project; kwargs...)::Project
    return register_item!(project, UNNAMED_ITEM_REGISTRATION; kwargs...)
end

"""
    register_collection!(project, level; members=nothing, process=nothing, analyze=nothing) -> project

Register the callbacks that run in every collection of one level, such as `:device`: a level that
the `collection` callback of [`register_item!`](@ref) names.

`process(data, metadata)` receives the data and the metadata of the collection's members, as
vectors, and returns new data for each member, in the same order. `analyze(data, metadata)`
receives the data that `process` returned and the members' metadata, and returns metadata that the
collection and each of its members get.

The members of a collection are all the items below it. `members` limits both callbacks to the items
of one registration, such as `:trace`; by default they receive every item. Registering the same
level and `members` again replaces the callbacks.
"""
function register_collection!(
    project::Project,
    level::Symbol;
    members::Union{Nothing,Symbol}=nothing,
    process=nothing,
    analyze=nothing,
)::Project
    recipe = CollectionRecipe(level, members, process, analyze, caller())
    index = findfirst(r -> r.level === level && r.members === members, project.collections)
    index === nothing ? push!(project.collections, recipe) : (project.collections[index] = recipe)
    return project
end

# The line of the project's code that called a `register_*!` function: the first one outside this
# package and Julia's own code.
function caller()::LineNumberNode
    for frame in stacktrace(backtrace())
        file = String(frame.file)
        (startswith(file, @__DIR__) || !isabspath(file)) && continue
        return LineNumberNode(frame.line, frame.file)
    end
    return LineNumberNode(0, :unknown)
end
