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
            (("process", recipe.process), ("analyze", recipe.analyze), ("label", recipe.label), ("id", recipe.id))
            if f !== nothing]
        steps = isempty(optional) ? "" : " · " * join(optional, " · ")
        print(io, "\n    ", rstrip(rpad(string(recipe.kind), pad) * steps))
    end
end

"""
Create an empty project. Register item recipes into it afterwards.

Results are kept in the file `values.duckdb`, in the folder of the Julia environment that is active
when the project is defined, so they stay available when the workspace opens again.
"""
function define_project(name::AbstractString; description::AbstractString="")::Project
    return Project(
        String(name),
        String(description),
        ItemRecipe[],
        joinpath(dirname(Base.active_project()), "values.duckdb"),
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
    process=nothing,
    analyze=nothing,
    label=nothing,
    id=nothing,
)::Project
    recipe = ItemRecipe(kind, detect, read, process, analyze, label, id, caller())
    index = findfirst(r -> r.kind === kind, project.recipes)
    index === nothing ? push!(project.recipes, recipe) : (project.recipes[index] = recipe)
    return project
end

function register_item!(project::Project; kwargs...)::Project
    return register_item!(project, UNNAMED_ITEM_REGISTRATION; kwargs...)
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
