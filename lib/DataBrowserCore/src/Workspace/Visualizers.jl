# The visualizers of a workspace.
#
# A *visualizer* of the workspace shows a value, such as a table or a plot of the selected items.
# It has an id, its settings, an input, and an optional function of the project, its *transform*,
# that the value passes through. Every client shows the same visualizers: the browser shows one in
# a window, and the window can close while the visualizer stays.
#
# ```julia
# v = visualize!(workspace, PlotView(plot="IV"))    # its input: the selection of the workspace
# t = visualize!(workspace, TableView(); input=v)   # its input: the output of v
# v.inspect = true                                  # a setting; every client that shows v follows
# close(v)                                          # v leaves the workspace
# ```
#
# The workspace computes the value of a visualizer in a task, once for all the clients that show
# it, and only while a client asks for it with `refresh!`, as a window of the browser does at each
# frame. A client prepares and draws the value with an instance of the visualizer type, which it
# owns; it can publish the output of that instance with `output!`, for a visualizer that takes its
# input from `v`.
#
# Clients on several threads read and change a visualizer at the same time. As with the shared
# state, a writer takes the lock of the shared state and replaces the definition of the visualizer
# whole, and a reader loads the definition without a lock.

"""
    LiveSelection()

The input of a visualizer that follows the selection of the workspace: the items selected in the
browser or with [`select!`](@ref), among those that the workspace has. It is the default input of
[`visualize!`](@ref).
"""
struct LiveSelection end

"""
    FixedItems(ids)

The input of a visualizer that keeps the items with the ids `ids` when the selection changes. The
visualizer leaves out the ids of items that the workspace does not have.
"""
struct FixedItems
    ids::Vector{String}
end

"""
Internal. The *definition* of a visualizer: the visualizer type and its label; the settings, by
name; the input; the transform, by name, so that a new definition of the function takes effect at
once, or `nothing`; how a client arranges the items of a selection, "auto", "stack", "grid" or
"overlay"; and the item that a stack shows. A writer replaces it whole, with [`define!`](@ref).
"""
const Definition = @NamedTuple{type::Type, label::String, settings::NamedTuple, input::Any,
    transform::Union{Nothing,GlobalRef}, arrangement::String, active_item::String}

"""
Internal. The *result* of a visualizer, which [`refresh!`](@ref) gives: its value; why the value could
not be computed, or ""; the computed values that the value leaves out because they failed, one on
each line; whether the workspace is processing the items of the input or computing the value; and
the number of times the value was computed, failures included, which is 0 before the first. After a
failure, the value is the one computed before.
"""
const Result = @NamedTuple{value::Any, error::String, failed::String, loading::Bool, revision::Int}

"""
Internal. What [`refresh!`](@ref) keeps from one call to the next, under `lock`: what the value was
last computed from; the stamp of the input, with what it was read from; the code revision of the
transform, with the world and the transform it was read for; the ids of the items of the input, with
what they were looked up from; and the task that computes the value.
"""
mutable struct Refresh
    const lock::ReentrantLock
    computed::Any
    checked::Any
    code::Tuple{Any,String}
    present::Tuple{Any,Vector{String}}
    task::Union{Nothing,Task}
end

"""
Internal. A visualizer of a workspace, which [`visualize!`](@ref) adds: its workspace, its id, its
[`Definition`](@ref), its latest [`Result`](@ref), and the output that a client published, as
`(revision, output)` with the revision of the result it was made from, or `nothing`. Its
properties are its settings: `v.name` reads the setting `name`, and `v.name = value` changes it.
"""
mutable struct Visualizer
    const workspace::Workspace
    const id::String
    @atomic definition::Definition
    @atomic result::Result
    @atomic output::Union{Nothing,Tuple{Int,Any}}
    const refresh::Refresh
end

# The number of the last visualizer added, in any workspace: it makes the ids of visualizers unique.
const VISUALIZERS = Threads.Atomic{Int}(0)

"""
    visualize!(workspace, visualizer; input=LiveSelection()) -> v

Add a visualizer to `workspace` that shows the value of `input` with `visualizer`, a new instance
of a visualizer type, such as `TableView()`, whose settings it takes. Return the visualizer `v` of
the workspace. The input is one of:

- `LiveSelection()`, the selection of the workspace, which `v` follows as it changes;
- `FixedItems(ids)`, the items with the ids `ids`;
- a function of the row of an item, which gives the items for which it returns `true`, as
  [`select(workspace, f)`](@ref select) gives them, and follows them as they change;
- another visualizer of the workspace, whose output `v` takes: for example the rows that the user
  selected in a table, or else the value of that visualizer.

`v.name` reads the setting `name` of `v`, and `v.name = value` changes it for every client that
shows `v`. `id(v)` gives the id of `v`, and `close(v)` removes it from the workspace.

```julia
v = visualize!(workspace, PlotView(plot="IV"))
t = visualize!(workspace, TableView(); input=v)
v.inspect = true
```

No client shows `v` yet: `visualize!(browser, v)` shows it in a window of the browser. The
workspace computes the value of `v` only while a client shows it.
"""
function visualize!(workspace::Workspace, visualizer::AbstractVisualizer; input=LiveSelection())::Visualizer
    v = Visualizer(workspace, "visualizer_$(Threads.atomic_add!(VISUALIZERS, 1) + 1)",
        (; definition(visualizer)..., input=LiveSelection(), transform=nothing, arrangement="auto",
            active_item=""),
        (; value=nothing, error="", failed="", loading=false, revision=0), nothing,
        Refresh(ReentrantLock(), nothing, nothing, (nothing, ""), (nothing, String[]), nothing))
    input!(v, input)
    share!(shared -> (; visualizers=Any[shared.visualizers; v]), workspace)
    return v
end

# The parts of a `Definition` that come from `visualizer`: its type, its label and its settings.
# Dynamic calls: a package defines its visualizer types after the caller compiled.
function definition(visualizer::AbstractVisualizer)
    names = keys(Base.invokelatest(DataBrowserAPI.settings, visualizer))
    return (; type=typeof(visualizer), label=Base.invokelatest(label, visualizer),
        settings=NamedTuple{names}(map(name -> getproperty(visualizer, name), names)))
end

"""
    id(v::Visualizer) -> String

The id of the visualizer `v`, unique in its workspace. It stays the same while `v` is in the
workspace.
"""
id(v::Visualizer)::String = getfield(v, :id)

Base.show(io::IO, v::Visualizer) = print(io, "Visualizer(", repr(id(v)), ", ", (@atomic v.definition).label, ")")

Base.propertynames(v::Visualizer, ::Bool=false) = keys((@atomic v.definition).settings)

function Base.getproperty(v::Visualizer, name::Symbol)
    definition = @atomic v.definition
    haskey(definition.settings, name) || error("$(definition.label) has no setting `$name`")
    return definition.settings[name]
end

function Base.setproperty!(v::Visualizer, name::Symbol, value)
    define!(v) do definition
        haskey(definition.settings, name) || error("$(definition.label) has no setting `$name`")
        value = convert(fieldtype(definition.type, name), value)
        return (; settings=merge(definition.settings, NamedTuple{(name,)}((value,))))
    end
    return value
end

"""
    define!(change, v)

Internal. Replace the [`Definition`](@ref) of `v` with the current one merged with
`change(definition)`, a named tuple of the parts that change. Writers take the lock of the shared
state, one at a time.
"""
function define!(change::Function, v::Visualizer)::Nothing
    @lock getfield(v, :workspace).shared_lock begin
        definition = @atomic v.definition
        @atomic v.definition = merge(definition, change(definition))
    end
    return nothing
end

"""
    input!(v, input)

Internal. Take the value of `v` from another input, one that [`visualize!`](@ref) takes. A
visualizer cannot take its value from itself, directly or through other visualizers.
"""
function input!(v::Visualizer, input)::Nothing
    input isa Union{LiveSelection,FixedItems,Function,Visualizer} || throw(ArgumentError(
        "A visualizer takes its value from LiveSelection(), FixedItems(ids), a function or another visualizer"))
    workspace = getfield(v, :workspace)
    @lock workspace.shared_lock begin
        if input isa Visualizer
            any(other -> other === input, (@atomic workspace.shared).visualizers) ||
                error("The input visualizer is not one of the workspace")
            (input === v || follows(input, v)) &&
                error("A visualizer cannot take its value from itself, directly or through other visualizers")
        end
        define!(_ -> (; input), v)
    end
    return nothing
end

"""
    follows(v, other) -> Bool

Internal. Whether `v` takes its value from the visualizer `other`, directly or through other
visualizers.
"""
function follows(v::Visualizer, other::Visualizer)::Bool
    input = (@atomic v.definition).input
    while input isa Visualizer
        input === other && return true
        input = (@atomic input.definition).input
    end
    return false
end

"""
    transform!(v, transform)

Internal. Pass the value of `v` through the function named by `transform`, a `GlobalRef`, before a
client shows it; `nothing` shows the value unchanged.

The function receives each item of the input, as `process` receives it, and returns the value to
show for it. A function with a method for a `Selection` and none for the items receives the whole
selection instead, and returns one value, such as a mean over the items. The value is computed again
when an input or the code of the function changes, and a client receives a selection of the results,
each with its computation. The tree of the workspace stays as it is, and the workspace keeps each
computation and its result until it closes.

A value of the input that is not a selection of items is passed to the function as it is.
"""
transform!(v::Visualizer, transform::Union{Nothing,GlobalRef})::Nothing = define!(_ -> (; transform), v)

"""
    visualizer!(v, visualizer)

Internal. Show the value of `v` with the type of `visualizer`, a new instance, whose settings `v`
takes. The items take the default arrangement again.
"""
visualizer!(v::Visualizer, visualizer::AbstractVisualizer)::Nothing =
    define!(_ -> (; definition(visualizer)..., arrangement="auto"), v)

"""
    arrangement!(v, mode)

Internal. Show the items of `v` in one of the arrangements "stack", "grid" or "overlay", or "auto",
which lets the client choose.
"""
function arrangement!(v::Visualizer, mode::String)::Nothing
    mode in ("auto", "stack", "grid", "overlay") || throw(ArgumentError("Unknown arrangement: $mode"))
    return define!(_ -> (; arrangement=mode), v)
end

"""
    active_item!(v, x)

Internal. Show the item with the public id `x` when the items of `v` are arranged as a stack.
"""
active_item!(v::Visualizer, x::String)::Nothing = define!(_ -> (; active_item=x), v)

"""
    output!(v, published)

Internal. Publish the output that a client made from the value of `v`, as `(revision, output)` with
the revision of the result it was made from; `nothing` withdraws it. A visualizer that takes its
input from `v` takes this output.
"""
output!(v::Visualizer, published::Union{Nothing,Tuple{Int,Any}})::Nothing = (@atomic v.output = published; nothing)

# The value that `v` passes on to a visualizer that takes its input from it: the output that a
# client published, or else the value of `v`.
function DataBrowserAPI.output(v::Visualizer)
    published = @atomic v.output
    return published === nothing || last(published) === nothing ? (@atomic v.result).value : last(published)
end

"""
    close(v::Visualizer)

Remove the visualizer `v` from its workspace. The browser closes the windows that show it, and a
visualizer that took its input from `v` follows the selection again.
"""
function Base.close(v::Visualizer)::Nothing
    share!(getfield(v, :workspace)) do shared
        for other in shared.visualizers
            (@atomic other.definition).input === v && define!(_ -> (; input=LiveSelection()), other)
        end
        return (; visualizers=filter(other -> other !== v, shared.visualizers))
    end
    return nothing
end

"""
    item_ids(v) -> Vector{String}

Internal. The ids of the items that the input of `v` names now, without those that the workspace
does not have: for an input visualizer, those that its input names. The result is kept for the next
calls: do not change it.
"""
function item_ids(v::Visualizer)::Vector{String}
    workspace, refresh, input = getfield(v, :workspace), getfield(v, :refresh), (@atomic v.definition).input
    input isa Visualizer && return item_ids(input)
    version = @atomic workspace.items.version
    named = if input isa LiveSelection
        (@atomic workspace.shared).selection
    elseif input isa FixedItems
        input.ids
    else
        ## The answer of `select(workspace, input)`, without waiting for it.
        found = answer(workspace, input).selection
        found === nothing ? String[] : found.id
    end
    ## Clients ask at each frame, and looking up each id costs time in proportion to the ids: they
    ## are looked up again when the ids named, or the ids of the workspace, are other objects.
    @lock refresh.lock begin
        first(refresh.present) === (named, version.index) && return last(refresh.present)
        ids = filter(x -> number(version, x) != 0, named)
        refresh.present = ((named, version.index), ids)
        return ids
    end
end

"""
    refresh!(v) -> Result

Internal. Bring the value of `v` up to date without waiting, and return its latest
[`Result`](@ref). When the input gives another value than before, or the code of the transform
changed, a task of the workspace computes the value again, as [`compute`](@ref) does. Before that,
the items of the input are processed ahead of background work, and the result says it is loading.
A client calls `refresh!` as long as it shows `v`, for example at each frame: the workspace
computes the value only while some client asks for it.
"""
function refresh!(v::Visualizer)::Result
    workspace, refresh = getfield(v, :workspace), getfield(v, :refresh)
    (; input, transform) = @atomic v.definition
    ## The input visualizer first, so that its value is up to date too.
    upstream = input isa Visualizer ? refresh!(input) : nothing
    @lock refresh.lock begin
        result = @atomic v.result
        ## One computation at a time: the call after it starts the next one.
        refresh.task === nothing || istaskdone(refresh.task) || return result
        loading(state) = result.loading == state ? result : (@atomic v.result = merge(result, (; loading=state)))
        version, world = (@atomic workspace.items.version), Base.get_world_counter()
        if upstream === nothing
            ids = item_ids(v)
            ## A function waits for its first answer.
            input isa Function && answer(workspace, input).selection === nothing && return loading(true)
            basis = (input, ids, version.generation, world)
        elseif !isempty(upstream.error)
            ## A failed input visualizer fails `v`, which computes its value again once the input
            ## recovers.
            refresh.computed = nothing
            error = "Input visualizer ($((@atomic input.definition).label)) failed:\n" * upstream.error
            error == result.error && return result
            return @atomic v.result = (; result.value, error, failed="", loading=false, revision=result.revision + 1)
        else
            ## The value waits for the value of the input visualizer, and for the output that a
            ## client makes from it.
            published = @atomic input.output
            (upstream.loading || upstream.revision == 0 ||
                published !== nothing && first(published) != upstream.revision) && return loading(true)
            given = DataBrowserAPI.output(input)
            basis = (input, given, version.generation, world)
        end
        ## Another stamp of the input means another value. Reading the stamp costs time in
        ## proportion to the items, so it is read again only when what it is read from changed: the
        ## input and the ids or the output that it gives, by identity, the generation of the latest
        ## version of the table `items`, or a method definition. A visualizer returns the same
        ## output object until its output changes.
        if refresh.checked === nothing || first(refresh.checked) !== basis
            stamp = upstream === nothing ? (version.catalog, hash(ids), revision(version, ids)) :
                foldl((seed, x) -> hash(revision(workspace, x), seed),
                    given isa AbstractVector{<:Computation} ? given : Computation[]; init=objectid(given))
            refresh.checked = (basis, stamp)
        end
        ## The code revision of the transform is read again after a method definition.
        if transform !== nothing && first(refresh.code) != (world, transform)
            f = Base.invokelatest(getglobal, transform.mod, transform.name)
            refresh.code = ((world, transform), code_revision(Any[f]).hash)
        end
        current = (last(refresh.checked), transform, transform === nothing ? "" : last(refresh.code))
        current == refresh.computed && return loading(false)
        upstream === nothing && !processed(workspace, ids) && return loading(true)
        refresh.computed = current
        loading(true)
        upstream === nothing && (given = FixedItems(ids))
        name = (@atomic v.definition).label
        refresh.task = track_task!(workspace, Threads.@spawn begin
            value, error, failed = result.value, "", ""
            try
                value, failed = Base.invokelatest(compute, workspace, given, transform)
            catch err
                error, _ = DataBrowserAPI.report_error("Failed to compute the value of $name", err, catch_backtrace())
            end
            @lock refresh.lock begin
                @atomic v.result = (; value, error, failed, loading=false, revision=(@atomic v.result).revision + 1)
            end
        end)
        return @atomic v.result
    end
end

"""
    compute(workspace, given, transform) -> (value, failed)

Internal. The value of a visualizer: `given`, the value of its input, passed through the function
named by `transform`, or unchanged when it is `nothing`. Also return why computations failed, one
line each: the value leaves out their items. Kept items, `FixedItems`, are read as a `Selection`,
which waits for items that are not processed yet.
"""
function compute(workspace::Workspace, given, transform::Union{Nothing,GlobalRef})
    failures = String[]
    ## The computations as a `Selection`, whose data is their results; the workspace stays as it
    ## is. Each has the metadata in `inherited`, of the item it was computed from. A
    ## computation that gives an item has the id and label of that item, and its metadata on top.
    ## TODO: any other computation is named by `label(value)`, only its function as "doubled"; it
    ## should read "doubled(n1)", from the computation itself.
    function resolve(values, inherited=[Dict{Symbol,Any}() for _ in values])
        computed, named, metadatas = Computation[], Any[], Dict{Symbol,Any}[]
        for (value, from) in zip(values, inherited)
            try
                result = evaluate(workspace, value)
                gives_item = result isa AbstractDataItem
                push!(computed, value)
                push!(named, gives_item ? result : value)
                push!(metadatas, gives_item ? merge(from, metadata_dict(metadata(result))) : from)
            catch err
                ## The workspace reports a failed computation as an `ErrorException` with its message.
                err isa ErrorException || rethrow()
                push!(failures, "$(label(value)): $(first(split(err.msg, '\n')))")
            end
        end
        ## A computed value belongs to no group and has no tags. Its metadata keys come in
        ## alphabetical order.
        names = sort!(unique(name for values in metadatas for name in keys(values)))
        return Selection(ItemData(workspace, computed), id.(named), label.(named), [String[] for _ in named],
            [String[] for _ in named], [name => [get(values, name, missing) for values in metadatas] for name in names])
    end
    given isa FixedItems && (given = select(workspace, given.ids))
    given isa AbstractVector{<:Computation} && (given = resolve(given))
    if transform !== nothing
        f = Base.invokelatest(getglobal, transform.mod, transform.name)
        if given isa Selection
            whole = Base.invokelatest(hasmethod, f, Tuple{Selection}) &&
                !all(item -> Base.invokelatest(applicable, f,
                    item isa Computation ? evaluate(workspace, item) : item), items(given))
            calls = whole ? [Computation(f, given)] :
                [Computation(f, computation(given, i)) for i in eachindex(given)]
            ## A value computed from one item keeps the columns of its row, other than `id`, `label`,
            ## `groups` and `tags`: the metadata of the item.
            columns = pairs(Base.structdiff(Tables.columns(given), NamedTuple{(:id, :label, :groups, :tags)}))
            inherited = whole ? [Dict{Symbol,Any}()] : [Dict{Symbol,Any}(name => column[i]
                for (name, column) in columns if !ismissing(column[i])) for i in eachindex(given)]
            given = resolve(calls, inherited)
        else
            given = evaluate(workspace, Computation(f, given))
        end
    end
    return given, join(failures, '\n')
end
