# How the rows of a workspace run. Each worker takes a job from the catalog and runs it:
#
# ```text
#     take! a job ─▶ the version of its row ─▶ did the cache record this version?
#                                                 │ no                     │ yes
#                                                 ▼                        ▼
#                              call the function with the        take the recorded result
#                              results of the inputs             or failure: nothing runs
#                                │ returns         │ throws
#                                ▼                 ▼
#                    keep the result in      record the failure
#                    the store of its type   for the next session
#                                │                 │
#                                ▼                 ▼
#                     finish!: current      finish!: failed
#                     finished!: the pipeline
#                     adds the rows that the
#                     result calls for
# ```
#
# The rows themselves, their states and the rules they follow are in
# [`Catalogs.jl`](../Catalogs.md); the rows that the workspace adds for the project are in
# [`Pipeline.jl`](Pipeline.md).

# ## Workers
#
# Worker tasks run the rows: one for each Julia thread, and at least two. Rows run in this order of
# priority:
#
# 1. what a view asks for: items, then collections;
# 2. source items;
# 3. the `process` of items, in the background;
# 4. collection rows and member rows, in the background.
#
# While the items that source items gave and that wait for their `process` fill half of
# `expanded_data_limit`, the `process` of items comes before source items, which frees that memory
# (`pace!` in [`Pipeline.jl`](Pipeline.md)). Background work is an option of `open_workspace`
# (`background_processing`): without it, source items are read, and items are processed only when a
# view asks for them.

function start_workers!(workspace::Workspace)::Nothing
    Threads.nthreads() == 1 && @warn("Julia runs with one thread: the browser waits while a computation runs. Start Julia with `--threads=auto`.", maxlog=1)
    for _ in 1:max(2, Threads.nthreads())
        push!(workspace.workers, Threads.@spawn work!(workspace))
    end
    return nothing
end

function stop_workers!(workspace::Workspace)::Nothing
    close(workspace.catalog)
    foreach(wait, workspace.workers)
    empty!(workspace.workers)
    return nothing
end

function work!(workspace::Workspace)::Nothing
    catalog = workspace.catalog
    while true
        job = @lock catalog.lock begin
            job = take!(catalog)
            while job === nothing && !catalog.closed
                wait(catalog.changed)
                job = take!(catalog)
            end
            catalog.closed || (workspace.running += 1)
            catalog.closed ? nothing : job
        end
        job === nothing && return nothing
        changed!(workspace)
        try
            # The latest world, so that a job runs the code defined after the worker started.
            Base.invokelatest(run!, workspace, job)
        catch error
            @error "A job of the workspace failed" exception=(error, catch_backtrace())
        finally
            @lock catalog.lock (workspace.running -= 1; workspace.completed += 1; notify(catalog.changed))
            changed!(workspace)
        end
    end
end

"""
Compute the row of `job`, keep its result, and add the rows that its result calls for. A row whose
version the cache recorded takes that record instead of running.
"""
function run!(workspace::Workspace, job::Job)::Nothing
    catalog, row = workspace.catalog, job.row
    value, place, expected, at, record = @lock catalog.lock begin
        place = get(workspace.places, row, nothing)
        at = version(workspace, row)
        expected = place isa CollectionKey ? AbstractCollection :
            place isa ItemKey && !isempty(workspace.tree[place].source) ? AbstractDataItem : Any
        catalog[row], place, expected, at, recorded(workspace, row, at)
    end
    if record !== nothing
        @lock catalog.lock begin
            finish!(catalog, job; failed=!isempty(record.failure), version=at, type=record.type) &&
                restored!(workspace, row, record)
            publish!(workspace)
        end
        return nothing
    end
    output = try
        call(workspace, row, value)
    catch error
        return failed!(workspace, job, at, error, catch_backtrace())
    end
    output isa expected || return failed!(workspace, job, at,
        ErrorException("$(function_name(value.f)) returned a $(typeof(output)), not a $expected"), nothing)
    iscurrent(catalog, job) && keep!(workspace, row, output)
    @lock catalog.lock begin
        finish!(catalog, job; version=at, type=typeof(output)) || return nothing
        delete!(workspace.errors, row)
        store_computation_revision!(workspace.cache.db, name(workspace, row), at, typeof(output))
        finished!(workspace, row, place, output)
        output isa ExpandedItems && keep_expanded!(workspace, row, output)
        foreach(input -> drop_used!(workspace, input), Catalogs.inputs(catalog, row))
        place isa String && collections!(workspace)
        publish!(workspace)
    end
    return nothing
end

"""Record that the row of `job` failed, with its message, also for the next session."""
function failed!(workspace::Workspace, job::Job, at::UInt64, error, backtrace)::Nothing
    catalog, row = workspace.catalog, job.row
    context = @lock catalog.lock begin
        f, place = catalog[row].f, get(workspace.places, row, nothing)
        subject = place isa String ? "Source item: $place" :
            place isa ItemKey ? "Function: $(function_name(f))\n  Item: $(workspace.tree[place].id)" :
            place isa CollectionKey ? "Function: $(function_name(f))\n  Collection: $(workspace.tree[place].id)" :
            "Computation: $(name(workspace, row))"
        "A computation failed\n  $subject\n  Source: $(DataBrowserAPI.source_description(workspace.source))"
    end
    message = DataBrowserAPI.error_summary(error, backtrace) * "\n\n" * context
    @lock catalog.lock begin
        finish!(catalog, job; failed=true) || return nothing
        workspace.errors[row] = failure_prefix(catalog[row].f) * message
        store_computation_revision!(workspace.cache.db, name(workspace, row), at, Nothing; failure=message)
        place = get(workspace.places, row, nothing)
        place isa String && (remove_items!(workspace, place); collections!(workspace))
        publish!(workspace)
    end
    DataBrowserAPI.report_error(context, error, backtrace)
    return nothing
end

failure_prefix(f)::String = f === read_items ? "could not create items: " : "$(function_name(f)) failed: "

"""
The message of the failed row that `row` waits for, or of `row` itself when it failed.
"""
function failure(workspace::Workspace, row::Row)::String
    catalog = workspace.catalog
    @lock catalog.lock while Catalogs.state(catalog, row) != Catalogs.FAILED
        stuck = findfirst(input -> Catalogs.stuck(catalog, input), Catalogs.inputs(catalog, row))
        stuck === nothing && return catalog.closed ? "The workspace was closed" : "The computation was removed from the workspace"
        row = Catalogs.inputs(catalog, row)[stuck]
    end
    return get(workspace.errors, row, "The computation failed")
end

"""
Run the function of `row` with the results of its inputs, and record how long it took.
"""
function call(workspace::Workspace, row::Row, value::Computation)
    args = map(x -> resolved(workspace, x), value.args)
    started, succeeded = time_ns(), false
    try
        output = Base.invokelatest(value.f, args...; value.settings...)
        succeeded = true
        return output
    finally
        execution = ComputationExecution((time_ns() - started) / 1.0e9, now(), succeeded)
        @lock workspace.catalog.lock row in workspace.catalog && (workspace.executions[row] = execution)
    end
end

# The value that a function receives for an argument: an input is the result of its row, and a
# part is the item that `process` receives.
resolved(workspace::Workspace, x::Input) = only(results(workspace, [x.row]))
resolved(workspace::Workspace, x::Part) = process_input(resolved(workspace, x.of), x.id)
resolved(workspace::Workspace, x::Tuple) = map(v -> resolved(workspace, v), x)
function resolved(workspace::Workspace, x::AbstractVector)
    # The members of a collection, read together, in a vector of their common type.
    eltype(x) === Input && return identity.(results(workspace, Row[v.row for v in x]))
    return any(v -> v isa Union{Input,Part,Tuple,AbstractVector}, x) ? map(v -> resolved(workspace, v), x) : x
end
resolved(::Workspace, x) = x
resolved(::Workspace, x::Selection) = x

# ## Names and versions
#
# Each row has a name and a version. The name is its function with the name of each argument, as
# `fit(sample)`, or the name that the pipeline gives it. The version is a hash of the name of its
# function, the revision of its code, the versions of its inputs, and its other arguments and
# settings: the same version means the same result, also in another session. The cache records,
# under the name of each row, the version of its last result, and its error when it failed.
#
# When a workspace opens again, a row whose recorded version is its current version is current, or
# failed with its recorded error, without running. Its metadata is the metadata the cache saved, and
# its value comes from its store; a store that no longer has it, such as a `MemoryStore`, computes
# it again when something needs it.

"""
The name of a row, under which the cache records its version and its store keeps its result: its
function and the name of each argument, or the name that the pipeline gave it.
"""
name(workspace::Workspace, row::Row)::String =
    get!(() -> call_id(workspace.catalog[row], x -> argument_name(workspace, x)), workspace.names, row)
argument_name(workspace::Workspace, x::Input) = name(workspace, x.row)
argument_name(::Workspace, x::Part) = x.id
argument_name(workspace::Workspace, x::Union{Tuple,AbstractVector}) = "[" * join(map(v -> argument_name(workspace, v), x), ", ") * "]"
argument_name(::Workspace, x::Selection) = argument_id(x)
argument_name(::Workspace, x) = argument_id(x)

"""
The version of the result that `row` gives now: the same version means the same result, also in
another session. It follows the code of its function, the versions of its inputs, and its other
arguments and settings. The caller holds the catalog lock.
"""
function version(workspace::Workspace, row::Row)::UInt64
    value = workspace.catalog[row]
    signature = Tuple{typeof(value.f),map(x -> argument_type(workspace, x), value.args)...}
    workspace.signatures[row] = signature
    # Types and symbols hash differently in another session; their names do not.
    seed = hash(function_name(value.f), hash(code!(workspace, signature, value.f).revision.hash))
    for x in value.args
        seed = hash(argument_version(workspace, x), seed)
    end
    return hash(repr(value.settings), seed)
end

argument_type(workspace::Workspace, x::Input) = Catalogs.result_type(workspace.catalog, x.row)
argument_type(workspace::Workspace, x::Part) = workspace.tree[workspace.tree.item_ids[x.id]].type
argument_type(::Workspace, x) = typeof(x)

argument_version(workspace::Workspace, x::Input)::UInt64 = Catalogs.version(workspace.catalog, x.row)
argument_version(workspace::Workspace, x::Part)::UInt64 = hash(x.id, argument_version(workspace, x.of))
argument_version(workspace::Workspace, x::Union{Tuple,AbstractVector{Input}})::UInt64 =
    foldl((seed, v) -> hash(argument_version(workspace, v), seed), x; init=UInt64(0))
argument_version(workspace::Workspace, x::Selection)::UInt64 =
    foldl((seed, row) -> hash(Catalogs.version(workspace.catalog, row), seed), Catalogs.rows(x); init=hash(argument_id(x)))
# A source item without a fingerprint may have changed at any time: its result is never the recorded one.
argument_version(::Workspace, x::AbstractDataSourceItem)::UInt64 =
    fingerprint(x) === nothing ? rand(UInt64) : hash(id(x), hash(repr(fingerprint(x))))
argument_version(::Workspace, x::AbstractCollection)::UInt64 = hash(string(typeof(x)), hash(id(x),
    hash(repr(sort!(collect(metadata_dict(metadata(x))); by=first)))))
argument_version(::Workspace, x)::UInt64 = hash(argument_id(x))

"""
The code that the rows of `signature` run, followed from the roots that [`code_roots`](@ref) gives.
The caller holds the catalog lock.
"""
function code!(workspace::Workspace, signature::Type, f)::Code
    return get!(workspace.code, signature) do
        roots = Base.invokelatest(code_roots, workspace.project, signature, f)
        code = Code(f, roots, Base.get_world_counter(), code_revision(roots))
        warn_untracked(signature, code)
        code
    end
end

"""
The functions, methods and types whose code a call of `signature` runs: for the calls of the
pipeline, what [`stage_roots`](@ref) gives for the type they run for; else the function. A
callable object that is not a function, such as a fit, runs the call methods of its type, whose
parameters name the functions it holds.
"""
function code_roots(project::AbstractProject, signature::Type, f)::Vector
    found = stage(signature)
    found === nothing || return stage_roots(project, found...)
    return f isa Function ? Any[f] : Any[typeof(f); collect(methods(f))]
end

stage(::Type{<:Tuple{typeof(read_items),Any,Any,S}}) where {S} = (SOURCE_READ, S)
stage(::Type{<:Tuple{typeof(process),Any,I}}) where {I} = (ITEM_PROCESS, I)
stage(::Type{<:Tuple{typeof(process),Any,C,AbstractVector}}) where {C<:AbstractCollection} = (COLLECTION_PROCESS, C)
stage(::Type{<:Tuple{typeof(process),Any,Any,C}}) where {C<:AbstractCollection} = (MEMBER_PROCESS, C)
stage(_) = nothing

"""
What the cache recorded for the result of `row` at `version`, when it can be used now: a failure,
or a result whose metadata the cache saved for an item or a collection. The caller holds the
catalog lock.
"""
function recorded(workspace::Workspace, row::Row, at::UInt64)
    record = recorded_revision(workspace.cache.db, name(workspace, row))
    (record === nothing || record.revision != at) && return nothing
    place = get(workspace.places, row, nothing)
    # TODO: a computed item that takes a recorded result has no metadata.
    saves = place isa CollectionKey || place isa ItemKey && !isempty(workspace.tree[place].source)
    isempty(record.failure) && saves && !haskey(workspace.saved, name(workspace, row)) && return nothing
    return record
end

"""
Give `row` the result that the cache recorded for it, when its version is the recorded one and its
inputs are current. The caller holds the catalog lock.
"""
function restore!(workspace::Workspace, row::Row)::Bool
    catalog = workspace.catalog
    Catalogs.state(catalog, row) in (Catalogs.MISSING, Catalogs.STALE) || return false
    all(input -> Catalogs.state(catalog, input) == Catalogs.CURRENT, Catalogs.inputs(catalog, row)) || return false
    at = version(workspace, row)
    record = recorded(workspace, row, at)
    record === nothing && return false
    Catalogs.restore!(catalog, row; failed=!isempty(record.failure), version=at, type=record.type) || return false
    restored!(workspace, row, record)
    return true
end

function restored!(workspace::Workspace, row::Row, record)::Nothing
    saved = pop!(workspace.saved, name(workspace, row), nothing)
    if !isempty(record.failure)
        workspace.errors[row] = failure_prefix(workspace.catalog[row].f) * record.failure
    elseif saved !== nothing
        store!(workspace.produced, row.index, saved)
    end
    return nothing
end

# ## Results
#
# `storage(project, T)` chooses the store for results of type `T`: items, or any other Julia value.
# The default is a `MemoryStore` of 64 MiB for each result type. A store of `nothing` keeps no
# results of that type: they are computed again when something needs them. A store receives a copy
# of each result and gives copies; `AbstractStore` lists its methods. The result of a view is not
# stored.

"""
The store that the project chooses for results of `type`; `nothing` for the results that are
kept in memory or made again when needed.
"""
function store(workspace::Workspace, type::Type)::Union{Nothing,AbstractStore}
    type <: Union{Nothing,ExpandedItems,Selection} && return nothing
    return @lock workspace.stores_lock get!(workspace.stores, type) do
        Base.invokelatest(DataBrowserAPI.storage, workspace.project, type)
    end
end

"""
Save the result of `row` in its store. A view is made again when needed: another copy would push
kept results out.
"""
function keep!(workspace::Workspace, row::Row, output)::Nothing
    catalog = workspace.catalog
    title, again = @lock catalog.lock (name(workspace, row), catalog[row].f === view)
    again && return nothing
    place = store(workspace, typeof(output))
    # `deepcopy` is a dynamic call: a method of a package loaded later then does not invalidate this code.
    place === nothing || write(place, title, Base.invokelatest(deepcopy, output))
    return nothing
end

"""
The results of `rows`, which are current: from memory, from their stores, read together for each
type, or else computed again.
"""
function results(workspace::Workspace, rows::Vector{Row})::Vector{Any}
    found = kept(workspace, rows)
    return Any[value === nothing ? computed!(workspace, row) : something(value) for (row, value) in zip(rows, found)]
end

function kept(workspace::Workspace, rows::Vector{Row})::Vector{Union{Nothing,Some}}
    catalog = workspace.catalog
    found = Vector{Union{Nothing,Some}}(nothing, length(rows))
    by_type = Dict{Type,Vector{Int}}()
    names = @lock catalog.lock map(enumerate(rows)) do (position, row)
        given = get(workspace.expanded, row, nothing)
        type = Catalogs.result_type(catalog, row)
        if given !== nothing
            found[position] = Some(first(given))
        elseif type === Nothing
            found[position] = Some(nothing)
        else
            push!(get!(Vector{Int}, by_type, type), position)
        end
        name(workspace, row)
    end
    for (type, positions) in by_type
        place = store(workspace, type)
        place === nothing && continue
        for (position, value) in zip(positions, read(place, type, names[positions]))
            value === nothing || (found[position] = Some(value))
        end
    end
    return found
end

"""Compute the result of a current row again, once for all the tasks that ask for it, and keep it."""
function computed!(workspace::Workspace, row::Row)
    catalog = workspace.catalog
    one = @lock catalog.lock get!(ReentrantLock, workspace.row_locks, row)
    @lock one begin
        found = only(kept(workspace, [row]))
        found === nothing || return something(found)
        value, before = @lock catalog.lock (catalog[row], Catalogs.revision(catalog, row))
        output = call(workspace, row, value)
        @lock catalog.lock begin
            Catalogs.revision(catalog, row) == before || return output
            output isa ExpandedItems && return (keep_expanded!(workspace, row, output); output)
        end
        keep!(workspace, row, output)
        return output
    end
end

"""
Forget what the workspace kept for the rows that lost their result or were removed, and tell
watchers that something changed. The caller holds the catalog lock.
"""
function publish!(workspace::Workspace)::Nothing
    catalog = workspace.catalog
    for row in lost!(catalog)
        forget_expanded!(workspace, row)
        delete!(workspace.executions, row)
        delete!(workspace.errors, row)
        Catalogs.state(catalog, row) == Catalogs.REMOVED || continue
        title = pop!(workspace.names, row, nothing)
        if title !== nothing
            type = Catalogs.result_type(catalog, row)
            place = store(workspace, type)
            place === nothing || delete!(place, type, title)
            delete_computation_revision!(workspace.cache.db, title)
        end
        delete!(workspace.produced, row.index)
        foreach(found -> delete!(found, row), (workspace.places, workspace.signatures, workspace.row_locks, workspace.evaluated))
    end
    # Wakes the tasks that wait for the scan or for the workspace to be idle.
    notify(catalog.changed)
    changed!(workspace)
    return nothing
end

# ## Code changes
#
# Each signature of a row, its function and the types of its arguments, has a code revision: a
# content hash of the code it can reach from its roots ([`CodeRevisions.jl`](../CodeRevisions.md)).
# The roots of a row of the pipeline are `stage_roots(project, stage, type)`; a Recipes project
# lists its registered callbacks. The roots of any other row are its function. A callable object
# that is not a function, such as a fit, has its type and its call methods as roots: the parameters
# of the type name the functions it holds, such as the curve of the fit. The walk follows only `Main`
# and packages developed from a local folder (`Pkg.develop`); for every other package, the Julia
# version and the Manifest count instead.
#
# The version of each result includes the revision of its code. Twice a second, the workspace asks
# Revise to load saved edits, including files tracked with `includet`, even when the REPL is idle.
# After a method definition, or when the roots differ, it computes the revision again; `evaluate`
# does the same check first when a method was defined since the last check. When the revision
# changed, the rows of that signature become stale, and with them every row that reads them: source
# items are read again, as if the source had changed them, and items and collections are processed
# again. Collections ask `has_stage` again, so a collection `process` defined later gets its rows.
# The same code defined again, as when a script runs again, changes nothing.
#
# While a browser is open, the keyboard focus of its main window controls these checks: an inactive
# window pauses them, and gaining focus resumes them. Without a browser, including after closing
# one, the workspace keeps checking.
#
# The revision does not see a mutable value changed in place, nor a change to a macro: the functions
# that use a macro keep their old expansion until they are defined again. It warns about code it
# cannot follow: a non-constant global, a call through `eval`, `invokelatest` or a computed name, a
# generated function, and a value it cannot read. The warning names the way from the root to it.

"""
Make the results whose code changed stale, so that they are computed again. The revision of the
code of a signature is computed again only when a method was defined since, or when
[`code_roots`](@ref) gives other roots. A collection `process` or member `process` methods may be
defined now, or no longer.
"""
function check_code!(workspace::Workspace)::Nothing
    catalog = workspace.catalog
    known = @lock catalog.lock copy(workspace.code)
    world = Base.get_world_counter()
    current = Dict{Type,Code}()
    for (signature, code) in known
        roots = code_roots(workspace.project, signature, code.f)
        code.world == world && isequal(code.roots, roots) && continue
        current[signature] = Code(code.f, roots, world, code_revision(roots))
        warn_untracked(signature, current[signature], code)
    end
    isempty(current) && return nothing
    @lock catalog.lock begin
        workspace.closed && return nothing
        changed = Set{Type}(signature for (signature, code) in current
            if code.revision.hash != workspace.code[signature].revision.hash)
        for signature in changed
            before, after = workspace.code[signature].revision.parts, current[signature].revision.parts
            @info("The code of a computation changed: its results are computed again",
                signature, changes=sort!(unique!(first.(symdiff(before, after)))))
        end
        merge!(workspace.code, current)
        for (row, signature) in workspace.signatures
            signature in changed && Catalogs.invalidate!(catalog, row)
        end
        before = copy(workspace.stages)
        empty!(workspace.stages)
        for key in collections(workspace)
            value = workspace.tree[key].value
            # The collections of computed values belong to the workspace: the project never processes them.
            value isa ComputedCollection && continue
            stages(workspace, value) == get(before, typeof(value), nothing) || members_changed!(workspace, key)
        end
        collections!(workspace)
        publish!(workspace)
    end
    return nothing
end

"""
Warn when code that a computation runs may change without the workspace noticing, once for each
new reason.

TODO: show this in the browser, next to the computation.
"""
function warn_untracked(signature::Type, code::Code, previous=nothing)::Nothing
    reasons = setdiff(code.revision.untracked, previous === nothing ? String[] : previous.revision.untracked)
    isempty(reasons) || @warn("Some code of a computation is not tracked: after changing it, reopen the workspace",
        signature, reasons)
    return nothing
end

# ## Computations

"""
`value` with each data item among its arguments that is an item of the workspace replaced by the
row of its latest value, so that it follows the changes of that item. The caller holds the catalog
lock.
"""
bound(workspace::Workspace, value::Computation) =
    Computation(value.f, map(x -> bound_argument(workspace, x), value.args), value.settings)
bound_argument(workspace::Workspace, x::Computation) = bound(workspace, x)
function bound_argument(workspace::Workspace, x::AbstractDataItem)
    key = get(workspace.tree.item_ids, id(x), nothing)
    key === nothing && return x
    return something(workspace.tree[key].member, workspace.tree[key].row, Some(x))
end
bound_argument(workspace::Workspace, x::Tuple) = map(v -> bound_argument(workspace, v), x)
bound_argument(workspace::Workspace, x::AbstractVector) =
    any(v -> v isa AbstractDataItem, x) ? map(v -> bound_argument(workspace, v), x) : x
bound_argument(::Workspace, x::Selection) = x
bound_argument(::Workspace, x) = x

# A selection reads the latest value of each of its items, and the result of each of its computations.
function Catalogs.rows(selection::Selection)::Vector{Row}
    data = selection.data::ItemData
    workspace = getfield(data, :workspace)
    found = Row[]
    for x in getfield(data, :items)
        row = x isa ItemKey ? something(workspace.tree[x].member, workspace.tree[x].row, Catalogs.NOWHERE) :
            get(workspace.catalog, bound(workspace, x), Catalogs.NOWHERE)
        row == Catalogs.NOWHERE || push!(found, row)
    end
    return found
end
Catalogs.argument(::Catalogs.Catalog, x::Selection, ::Bool) = x
DataBrowserCore.computation_inputs(selection::Selection) = Computation[computation(selection, i) for i in eachindex(selection)]
DataBrowserCore.evaluated(selection::Selection) = selection

"""
    evaluate(workspace, computation)

The result of `computation`, computed ahead of background work with the results that the workspace
keeps, and kept for later calls. The workspace keeps the computation until it closes. A failed
computation, or one whose input failed, throws its error.
"""
function evaluate(workspace::Workspace, value::Computation)
    catalog = workspace.catalog
    # Code defined since the last check makes its results stale before this one is read.
    world = Base.get_world_counter()
    @lock(catalog.lock, any(code -> code.world != world, values(workspace.code))) && Base.invokelatest(check_code!, workspace)
    row = @lock catalog.lock begin
        row = add!(catalog, bound(workspace, value))
        row in workspace.evaluated || (hold!(catalog, row); push!(workspace.evaluated, row))
        want!(catalog, row, VIEWED_ITEM)
        restore!(workspace, row)
        row
    end
    wait(catalog, row) == Catalogs.CURRENT || error(failure(workspace, row))
    return only(results(workspace, [row]))
end

"""
    computation(workspace, item) -> Computation

The computation that gives the latest value of an item, given as a key, a public id or a data item:
its member `process`, when the collections above it have member `process` methods, or else its own
`process`. Its [`inputs`](@ref) lead back to the source item it comes from. Reading it computes
nothing.
"""
computation(workspace::Workspace, value::Union{AbstractString,AbstractDataItem}) =
    computation(workspace, key(workspace, value))
function computation(workspace::Workspace, key::ItemKey)::Computation
    @lock workspace.catalog.lock begin
        item = workspace.tree[key]
        row = something(item.member, item.row, Some(nothing))
        row === nothing && error("The item \"$(item.id)\" waits for the source to report its source item")
        return workspace.catalog[row]
    end
end

"""
    computation(selection, index) -> Computation

The computation that gives one item of a selection. Reading it loads no data.
"""
function computation(selection::Selection, index::Integer)::Computation
    data = selection.data::ItemData
    item = getfield(data, :items)[index]
    return item isa Computation ? item : computation(getfield(data, :workspace), item)
end

# The row of a computation, or `nothing` when the workspace does not have it.
function row(workspace::Workspace, value::Computation)::Union{Nothing,Row}
    found = @lock workspace.catalog.lock get(workspace.catalog, bound(workspace, value), Catalogs.NOWHERE)
    return found == Catalogs.NOWHERE ? nothing : found
end

# The time of an execution covers the call of the function, with compilation and waits, and not the
# evaluation of its inputs or the storage of its result.
function last_execution(workspace::Workspace, value::Computation)::Union{Nothing,ComputationExecution}
    found = row(workspace, value)
    found === nothing && return nothing
    @lock workspace.catalog.lock Catalogs.state(workspace.catalog, found) in (Catalogs.CURRENT, Catalogs.FAILED) ?
        get(workspace.executions, found, nothing) : nothing
end

function cache_info(workspace::Workspace, value::Computation)
    found, catalog = row(workspace, value), workspace.catalog
    found === nothing && return (cached=false, bytes=nothing)
    type, title, current = @lock catalog.lock (Catalogs.result_type(catalog, found), name(workspace, found),
        Catalogs.state(catalog, found) == Catalogs.CURRENT)
    place = store(workspace, type)
    (current && place !== nothing && haskey(place, type, title)) || return (cached=false, bytes=nothing)
    return (cached=true, bytes=DataBrowserAPI.stored_size(place, type, title))
end

"""
    revision(workspace, computation) -> UInt

A number that changes when the result of `computation` changes: when it becomes current, or stops
being so. A view keeps the number it drew with, and draws again when it differs. Reading it
computes nothing.
"""
function revision(workspace::Workspace, value::Computation)::UInt
    found, catalog = row(workspace, value), workspace.catalog
    found === nothing && return UInt(0)
    return @lock catalog.lock hash(found.index, hash(Catalogs.state(catalog, found) == Catalogs.CURRENT, hash(Catalogs.revision(catalog, found))))
end

"""
The workspace whose kept results `data` and `metadata` of a `Computation` read. Outside of it, `data`
runs the call and its inputs directly.
"""
const CURRENT_WORKSPACE = ScopedValue{Union{Nothing,Workspace}}(nothing)

# A computation is an item whose data is its result.
function in_scope(value::Computation)
    workspace = CURRENT_WORKSPACE[]
    return workspace === nothing ? evaluate(value) : evaluate(workspace, value)
end

function data(value::Computation)
    result = in_scope(value)
    return result isa AbstractDataItem ? data(result) : result
end

# The metadata of the item that a computation gives in the workspace. Or else the metadata of the one
# item it reads, with the metadata of its result on top when that is an item.
function metadata(value::Computation)
    workspace = CURRENT_WORKSPACE[]
    found = workspace === nothing ? nothing : row(workspace, value)
    key = found === nothing ? nothing : @lock(workspace.catalog.lock, get(workspace.places, found, nothing))
    key isa ItemKey && return metadata(workspace, key)
    from = inputs(value)
    given = length(from) == 1 ? metadata(only(from)) : Dict{Symbol,Any}()
    result = in_scope(value)
    return result isa AbstractDataItem ? merge(given, metadata_dict(metadata(result))) : given
end

DataBrowserAPI.members(value::Computation) = AbstractDataItem[x for x in value.args if x isa AbstractDataItem]

"""
    select(workspace, items::AbstractVector) -> Selection

The items as a [`Selection`](@ref), without adding them to the workspace: computations, each an item
whose data is its result, or the items that functions returned. The results of the computations are
computed now, and the workspace keeps them.
"""
function select(workspace::Workspace, items::AbstractVector)::Selection
    with(CURRENT_WORKSPACE => workspace) do
        names = [x isa Computation ? computed_name(workspace, x) : (id(x), label(x)) for x in items]
        Selection(ItemData(workspace, items), first.(names), last.(names), metadata.(items))
    end
end

# The id and the label of a computation in a selection: those of the item it gives, or of its result
# when that is an item; or else its name.
function computed_name(workspace::Workspace, value::Computation)::Tuple{String,String}
    result = evaluate(workspace, value)
    catalog, found = workspace.catalog, row(workspace, value)
    key = @lock catalog.lock get(workspace.places, found, nothing)
    key isa ItemKey && return @lock catalog.lock (workspace.tree[key].id, workspace.tree[key].label)
    result isa AbstractDataItem && return (id(result), label(result))
    title = @lock catalog.lock name(workspace, found)
    return (title, title)
end

# ## Computed items

# The name of the function of computed values: it names the collection that holds them and starts
# their ids. A package whose computations are values of its own type gives them a name, and can
# give their values their own `id` and `label`.
# TODO: an anonymous function is named by its generated name, such as `#3`, which changes from
# session to session; name it by the content of its code (docs/plans/processing.md).
function_name(f) = string(nameof(f))

id(value::Computation) = call_id(value, argument_id)
# The function, then each argument as `name` writes it, then the settings.
call_id(value::Computation, name) = string(function_name(value.f), "(",
    join(map(name, value.args), ", "),
    isempty(value.settings) ? "" : "; " * join(("$name = $(repr(setting))" for (name, setting) in pairs(value.settings)), ", "),
    ")")
# TODO: the id of a computation repeats the ids of its inputs, so that the id of a member `process`
# names every member of the collection.
argument_id(x::Computation) = id(x)
argument_id(x::Input) = id(x.catalog[x.row])
argument_id(x::Part) = x.id
argument_id(x::AbstractDataItem) = id(x)
argument_id(x::AbstractProject) = project_name(x)
argument_id(x::Union{AbstractDataSource,AbstractDataSourceItem}) = id(x)
argument_id(selection::Selection) = "[" * join(selection.id, ", ") * "]"
argument_id(xs::Union{AbstractVector,Tuple}) = "[" * join(map(argument_id, xs), ", ") * "]"
argument_id(x) = repr(x)
label(value::Computation) = function_name(value.f)

"""
The collections of computed values: `Computed` at the root, and below it one for each function,
named after it.
"""
struct ComputedCollection <: AbstractCollection
    name::String
end
id(collection::ComputedCollection) = collection.name
label(collection::ComputedCollection) = collection.name

const COMPUTED = ComputedCollection("Computed")

# TODO: a rule for when the workspace drops a computed item. Today it keeps each one until it
# closes, also when nothing uses it any more.
"""
Add `value` to the workspace as an item, computed in the background once the items it reads are
processed. It is an item of the collection of its function, below the collection `Computed`. The
data items among its arguments that are items of the workspace are read in their latest version. A
value with the id of one added before takes its place, and is computed again when it reads other
items.
"""
function Base.push!(workspace::Workspace, value::Computation)::Workspace
    catalog, tree = workspace.catalog, workspace.tree
    @lock catalog.lock begin
        given = bound(workspace, value)
        known = get(tree.item_ids, id(value), nothing)
        if known !== nothing
            isempty(tree[known].source) || error("The workspace has an item with the id \"$(id(value))\" from its source")
            row = tree[known].row
            reads = unique!(Catalogs.rows(Catalogs.instanced(catalog, given; add=false).args))
            reads == Catalogs.inputs(catalog, row) || (replace!(catalog, row, given); publish!(workspace))
            return workspace
        end
        holder = collection!(tree, collection!(tree, ROOT, COMPUTED, Dict{Symbol,Any}()),
            ComputedCollection(function_name(value.f)), Dict{Symbol,Any}())
        key = item!(tree, id(value), label(value), typeof(value), holder, "", Dict{Symbol,Any}())
        row = add!(catalog, given)
        hold!(catalog, row)
        # A row of the pipeline keeps the item it gives.
        tree[key].row = row
        get!(workspace.places, row, key)
        get!(workspace.names, row, id(value))
        want!(catalog, row, BACKGROUND_ITEM)
        restore!(workspace, row)
        publish!(workspace)
    end
    return workspace
end

"""
Remove the computed item with `id` from the workspace, with its result. An id the workspace has no
computed item for changes nothing.
"""
function Base.delete!(workspace::Workspace, id::AbstractString)::Workspace
    @lock workspace.catalog.lock begin
        key = get(workspace.tree.item_ids, id, nothing)
        (key === nothing || !isempty(workspace.tree[key].source)) && return workspace
        remove_item!(workspace, key)
        publish!(workspace)
    end
    return workspace
end

"""
The results of the computed items with `ids`, as their functions returned them. Items that are not
computed yet are computed now, and the call waits for them.
"""
function results(workspace::Workspace, ids::AbstractVector{<:AbstractString})::Vector
    keys = ItemKey[key(workspace, id) for id in ids]
    wait_processed(workspace, keys)
    return results(workspace, @lock(workspace.catalog.lock, Row[workspace.tree[key].row for key in keys]))
end

# ## Items

"""
    materialize_items(workspace, items) -> Vector{AbstractDataItem}

The processed items for `items`, given as item keys or public ids, in the same order. Each item
comes in its latest version: the one its member `process` returned, when that is current, or else
its own processed data. A computed item is its computation, whose data is its result.

An item that is not processed yet is processed now, ahead of background work, and the call waits
for it. The member `process` of each item is requested too, and the call does not wait for it: a
later call delivers the later version once it is ready. A failed item throws its error.

The data and the metadata of each delivered item belong together: when an item changes while it is
loaded, it is loaded again.
"""
function materialize_items(workspace::Workspace, keys::Vector{ItemKey})::Vector{AbstractDataItem}
    catalog = workspace.catalog
    while true
        seen = wait_processed(workspace, keys)
        computed, rows = @lock catalog.lock begin
            computed = [isempty(workspace.tree[key].source) for key in keys]
            computed, Row[value_row(workspace, key) for key in keys]
        end
        found = results(workspace, rows[.!computed])
        delivered = AbstractDataItem[computed[i] ? catalog[rows[i]] : popfirst!(found) for i in eachindex(keys)]
        revision(workspace, keys) == seen && return delivered
    end
end

function materialize_items(workspace::Workspace, ids::AbstractVector{<:AbstractString})::Vector{AbstractDataItem}
    return materialize_items(workspace, ItemKey[key(workspace, id) for id in ids])
end

# Ask for the items ahead of background work: their own `process`, or the source item they wait
# for, and their member `process` after it.
function want_viewed!(workspace::Workspace, keys::Vector{ItemKey})::Nothing
    catalog = workspace.catalog
    @lock catalog.lock for key in keys
        item = workspace.tree[key]
        if item.row === nothing
            source = get(workspace.sources, item.source, nothing)
            source === nothing || want!(catalog, source, VIEWED_ITEM)
        else
            Catalogs.priority(catalog, item.row) >= VIEWED_ITEM || want!(catalog, item.row, VIEWED_ITEM)
        end
        item.member === nothing || Catalogs.priority(catalog, item.member) >= VIEWED_COLLECTION ||
            want!(catalog, item.member, VIEWED_COLLECTION)
    end
    return nothing
end

"""
    processed(workspace, items) -> Bool

Ask for `items` ahead of background work, as `select` does, and tell whether each is processed now,
or failed. The call does not wait, so a view can keep showing what it showed until the items are
ready.
"""
function processed(workspace::Workspace, keys::Vector{ItemKey})::Bool
    catalog = workspace.catalog
    @lock catalog.lock begin
        want_viewed!(workspace, keys)
        return catalog.closed || all(keys) do key
            row = workspace.tree[key].row
            row !== nothing && (Catalogs.state(catalog, row) in (Catalogs.CURRENT, Catalogs.FAILED) || Catalogs.stuck(catalog, row))
        end
    end
end

"""
Ask for `items` ahead of background work, wait until each is processed, and return their
[`revision`](@ref). A failed item throws its error.
"""
function wait_processed(workspace::Workspace, keys::Vector{ItemKey})::UInt
    catalog = workspace.catalog
    @lock catalog.lock begin
        want_viewed!(workspace, keys)
        for key in keys
            item = workspace.tree[key]
            while item.row === nothing && !item.removed && !catalog.closed
                wait(catalog.changed)
                want_viewed!(workspace, [key])
            end
            state = item.row === nothing ? Catalogs.REMOVED : wait(catalog, item.row)
            state == Catalogs.CURRENT && continue
            catalog.closed && error("The workspace was closed")
            state == Catalogs.REMOVED && error("The item \"$(item.id)\" was removed from the workspace while it was loaded")
            error(failure(workspace, item.row))
        end
        return revision(workspace, keys)
    end
end

"""
    revision(workspace, items) -> UInt

A number that changes when `materialize_items` would deliver different versions of `items`: an item
was processed again, or its member `process` became current or stopped being so. A view keeps the
number it drew with and draws again when it differs.
"""
function revision(workspace::Workspace, keys::Vector{ItemKey})::UInt
    catalog = workspace.catalog
    @lock catalog.lock begin
        seed = UInt(0)
        for key in keys, row in (workspace.tree[key].row, workspace.tree[key].member)
            seed = row === nothing ? hash(0, seed) : hash(row.index, hash(Catalogs.state(catalog, row) == Catalogs.CURRENT,
                hash(Catalogs.revision(catalog, row), seed)))
        end
        return seed
    end
end

"""
    status_revision(workspace) -> Int

A number that rises whenever a computation of this or any other workspace changes its state, is
added or is removed. Items are added and removed only together with such a change. While the number
stays the same, so do the [`revision`](@ref) of any items and the item that each public id names.
Reading it costs the same for any number of items.
"""
status_revision(::Workspace)::Int = Catalogs.CHANGES[]

"""
    read_first!(workspace, ids)

Read the source items with public ids `ids` ahead of background work, and ahead of the memory limit
for the items that wait for `process`. The call does not wait. Ids of source items that are read
already, or that the workspace does not have, are ignored. See [`unread`](@ref).
"""
function read_first!(workspace::Workspace, ids::AbstractVector{<:AbstractString})::Nothing
    catalog = workspace.catalog
    @lock catalog.lock for id in ids
        row = get(workspace.sources, id, nothing)
        row === nothing || Catalogs.priority(catalog, row) >= VIEWED_ITEM || want!(catalog, row, VIEWED_ITEM)
    end
    return nothing
end

"""
    unread(workspace) -> Vector{String}

The public ids of the source items that the source lists and the workspace has not read yet: their
items are not in the workspace. A source item that failed is not included. For a directory source,
an id is the path of a file below the source root.

[`read_first!`](@ref) reads chosen source items ahead of the others.
"""
unread(workspace::Workspace)::Vector{String} = @lock workspace.catalog.lock String[
    id for (id, row) in workspace.sources if Catalogs.state(workspace.catalog, row) in (Catalogs.MISSING, Catalogs.STALE)]

"""The jobs that ended, the jobs that ended, run or wait, and the jobs that run now."""
work_counts(workspace::Workspace)::Tuple{Int,Int,Int} = @lock workspace.catalog.lock (
    workspace.completed, workspace.completed + workspace.running + queued(workspace.catalog), workspace.running)
