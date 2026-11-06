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

"""
Create an empty project. Register item and collection recipes into it afterwards.

Results are kept in the file `values.duckdb`, in the folder of the Julia environment that is active
when the project is defined, so they stay available when the workspace opens again.
"""
function define_project(name::AbstractString; description::AbstractString="")::Project
    return Project(
        String(name),
        String(description),
        ItemRecipe[],
        CollectionRecipe[],
        joinpath(dirname(Base.active_project()), "values.duckdb"),
    )
end

const UNNAMED_ITEM_REGISTRATION = Symbol("#unnamed")

"""
    register_item!(project, [kind]; read, detect, expand, process, analyze, label, id, collection) -> project

Register or replace one item pipeline: the callbacks that make the items of `kind` from source
items, such as files. `read` is the only required callback. The callbacks after `read` receive the
data and the metadata of an item.

- `detect(source_item)` returns whether the pipeline reads the source item. The default accepts
  every source item. The first pipeline in the order of registration whose `detect` accepts a source
  item reads it. A source item that no pipeline accepts gives no item.
- `read(source_item)` returns the data of the source item, or `(data=..., metadata=...)`. The
  metadata of the item also holds the metadata of the source item, such as `:filename` for a file.
  The item has the id of the source item, such as `a.csv`.
- `expand(data, metadata)` returns a vector of entries, each data or `(data=..., metadata=...)`, for
  a source item that holds several items, such as a file with a table for each channel. Each entry
  is an item, with the metadata of `read` and its own, and the source item is not an item of `kind`.
  The entries are items once `process` runs for their source item: when the browser shows the source
  item or a script asks for it, or in the background with `background_processing=true`.
- `id(data, metadata)` returns the key of an entry, such as its channel number, so that the entry
  keeps its id when the order of the entries changes. The default is the position of the entry.
  The id of an entry is the id of its source item, the kind and the key, such as `a.csv#trace:2`.
- `process(data, metadata)` returns new data for the item.
- `analyze(data, metadata)` runs right after `process` on the processed data, and returns metadata
  that the processed item gets.
- `label(data, metadata)` returns the label of the item. It runs when the item is created, and again
  after `process` and `analyze` with the metadata they added, so a label can show analysis results
  once they exist.
- `collection(data, metadata)` returns a named tuple that names the collections of the item from the
  top level down, such as `(wafer = metadata[:wafer], device = metadata[:device])`.
  [`register_collection!`](@ref) registers the callbacks that run in the collections of a level.
  Without `collection`, the item is in no collection.

Returned metadata may be a dictionary, named tuple, single pair, or any iterable accepted
by `Dict`. Keys are converted to symbols and values must be supported metadata values.

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
    id=nothing,
    collection=nothing,
)::Project
    recipe = ItemRecipe(kind, detect, read, expand, process, analyze, label, collection, id, caller())
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

`process(data, metadata)` receives the data and the metadata of the items below the collection, as
vectors, and returns new data for each item, in the same order. `analyze(data, metadata)` receives
the data that `process` returned and the metadata of the items, and returns metadata for each item,
in the same order. A value that is the same for every item, such as the number of items, is
repeated in each item's metadata. When collections of two levels give an item new data, or
metadata under the same name, the higher level wins.

`members` limits both callbacks to the items of one registration, such as `:trace`; by default they
receive every item below the collection. Registering the same level and `members` again replaces
the callbacks.

Each collection is a group whose members are the collections and the items directly below it. Its id
names its levels from the top down: `wafer:W1/device:A` for `(wafer = "W1", device = "A")`. Only
the items of a `DirectorySource` are in collections.
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
