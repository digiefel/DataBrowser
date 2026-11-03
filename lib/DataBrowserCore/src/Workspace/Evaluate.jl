# A computation, `Computation(f, args...; settings...)`, is a function call before it runs: reading
# one source item, the `process` of one item, or a function of your own, such as a fit. The
# workspace keeps each computation in a row of its *catalog*, a table, with the state of the
# computation: missing, stale, current or failed ([`Catalogs.jl`](../Catalogs.md)). To compute a
# row, the workspace runs a *job*.
#
# The workspace adds four kinds of rows for the project ([`Pipeline.jl`](Pipeline.md)), and one row
# for each computation that a script or a window asks for:
#
# | Row            | Calls                                                     | Name, for the item `a/1` of `a.csv` |
# |:---------------|:----------------------------------------------------------|:------------------------------------|
# | source row     | `read_items(project, source, source_item)`: `read`, then `expand` | `read:a.csv`, which gives `a/1` |
# | own row        | `process(project, item)`                                  | `a/1`                               |
# | collection row | `process(project, collection, members)`                   | `collection:Runs(runs)`             |
# | member row     | `process(project, item, collection)`                      | `member:a/1`                        |
#
# Windows show the *latest value* of an item: the result of its last member row when that row is
# current, and else the result of its own row.
#
# Scripts ask for results with these functions:
#
# | Call                                | Gives                                  | Waits | Keeps in the workspace          |
# |:------------------------------------|:---------------------------------------|:------|:--------------------------------|
# | `materialize_items(workspace, ids)` | the items, with their latest value     | yes   | nothing new                     |
# | `evaluate(workspace, computation)`  | the result of a computation            | yes   | its row, until the workspace closes |
# | `push!(workspace, computation)`     | a computed item in the tree            | no    | the item, until `delete!`       |
# | `results(workspace, ids)`           | the results of computed items          | yes   | nothing new                     |
#
# Three parts of the workspace keep information about a row:
#
# ```text
#     catalog, in memory          the state of each row, its inputs and its priority
#     cache, a DuckDB file        for each row name: the version of its last result, or its error;
#                                 and the tree, with the metadata and labels of items and
#                                 collections. The next session knows from it which rows are
#                                 current, and shows the tree at once
#     stores, one for each        for each row name: its result. A MemoryStore, the default, loses
#       type of result            the results when Julia exits; a DuckDBStore, as a project made
#                                 with DataBrowserRecipes uses, keeps them in a file
# ```
#
# Each worker takes a job from the catalog and runs it:
#
# ```text
#     take! a job ─▶ compute the version of its row ─▶ did the cache save this version?
#                                                       │ no                    │ yes
#                                                       ▼                       ▼
#                                    call the function with the       finish!: the row is current,
#                                    results of its inputs            or failed with the saved
#                                      │                │             error. The function does not
#                                      │ returns a      │ throws, or  run: the value comes from its
#                                      │ result of the  │ returns     store when something needs it
#                                      │ right type     │ another type
#                                      ▼                ▼
#                          keep the result in     save the error
#                          the store of its type  in the cache
#                          and its version in
#                          the cache
#                                      │                │
#                                      ▼                ▼
#                          finish!: the row is    finish!: the row is
#                          current                failed
#                                      │
#                                      ▼
#                          finished!: the pipeline adds the rows that the result needs
#
#     finish! belongs to the catalog: it ends the job and sets the state of the row.
#     finished! belongs to the pipeline: it adds rows, such as the own row of each new item.
# ```
#
# The version of a row identifies its result (see "Names and versions"). A current row whose store
# no longer has its result runs again when something needs the result.

# ## Workers
#
# Worker tasks run the jobs: one for each Julia thread, and at least two. Jobs run in this order of
# priority, highest first:
#
# 1. what a window shows and what a script asks for: its items and computations (`VIEWED_ITEM`),
#    then the member rows of its items (`VIEWED_COLLECTION`);
# 2. source items, while the items that wait in memory take less than half of
#    `expanded_data_limit` (`SOURCES_FIRST`);
# 3. the `process` of items, in the background (`BACKGROUND_ITEM`);
# 4. source items, while the waiting items take more than half of `expanded_data_limit`
#    (`ITEMS_FIRST`);
# 5. collection rows and member rows, in the background (`BACKGROUND_COLLECTION`).
#
# Items read from a source item wait in memory until their `process` runs. Once they take more than
# half of `expanded_data_limit`, workers process waiting items before they read more source items,
# which frees that memory (`pace!` in [`Pipeline.jl`](Pipeline.md)). `expanded_data_limit` is an
# option of `open_workspace`, in MiB: 512 by default, or a quarter of the memory of the machine when
# that is less. By default, `open_workspace` sets `background_processing=false`: the workers read
# every source item, but process an item only when a window or a script asks for it.
#
# The `process` of an item read from the source must return a data item, and a collection `process`
# must return a collection; any other result fails the row. When a function throws, the row fails:
# the error is logged, the status panel of the browser shows the error next to its item, and the
# cache saves it. When reading a source item fails, its items leave the tree until a later read
# succeeds. A failed row does not run again, even in a later session, until its version changes: its
# code, an input or an argument changed. To run failed rows again without a change, open the
# workspace with `rebuild=true`, which empties its cache.
#
# When the store refuses a result, as a `DuckDBStore` refuses metadata of another type than the
# values it holds under that name, the row fails in the same way, but the cache does not save the
# error: the next session runs the row again.
#
# TODO: a way to run one failed row again, as after a file was locked for a moment.

"""
    start_workers!(workspace)

Start the worker tasks of the workspace: one for each Julia thread, and at least two.
"""
function start_workers!(workspace::Workspace)::Nothing
    Threads.nthreads() == 1 && @warn("Julia runs with one thread: the browser waits while a computation runs. Start Julia with `--threads=auto`.", maxlog=1)
    for _ in 1:max(2, Threads.nthreads())
        push!(workspace.workers, Threads.@spawn work!(workspace))
    end
    return nothing
end

"""
    stop_workers!(workspace)

Close the catalog and wait until each worker task has finished its job and ended.
"""
function stop_workers!(workspace::Workspace)::Nothing
    close(workspace.catalog)
    foreach(wait, workspace.workers)
    empty!(workspace.workers)
    return nothing
end

"""
    work!(workspace)

The loop of one worker task: take the job of highest priority, run it, and wait when there is
none, until the catalog closes.
"""
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
            ## The latest world, so that a job runs the code defined after the worker started.
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
    run!(workspace, job)

Compute the row of `job`, keep its result, and add the rows that its result needs. A row whose
current version is the one the cache saved becomes current, or failed, without running. A result of
the wrong type fails the row: the `process` of an item read from the source must return an
`AbstractDataItem`, and a collection `process` an `AbstractCollection`.
"""
function run!(workspace::Workspace, job::Job)::Nothing
    catalog, row = workspace.catalog, job.row
    ## Until `finish!` ends the job, every error fails the row, so that no row stays running without
    ## a job. The cache saves only the error of the function, under the version of the row: after
    ## any other error, the next session runs the row again.
    value, place, expected, at, record = try
        @lock catalog.lock begin
            place = get(workspace.places, row, nothing)
            at = version(workspace, row)
            expected = place isa CollectionKey ? AbstractCollection :
                place isa ItemKey && !isempty(workspace.tree[place].source) ? AbstractDataItem : Any
            catalog[row], place, expected, at, recorded(workspace, row, at)
        end
    catch error
        return failed!(workspace, job, nothing, error, catch_backtrace())
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
    try
        keepable(catalog, job) && keep!(workspace, row, output)
    catch error
        return failed!(workspace, job, nothing, error, catch_backtrace())
    end
    @lock catalog.lock begin
        finish!(catalog, job; version=at, type=typeof(output)) || return nothing
        delete!(workspace.errors, row)
        store_computation_revision!(workspace.cache.db, cachekey(workspace, row), at, typeof(output))
        finished!(workspace, row, place, output)
        output isa ExpandedItems && keep_expanded!(workspace, row, output)
        foreach(input -> drop_used!(workspace, input), Catalogs.inputs(catalog, row))
        place isa String && collections!(workspace)
        publish!(workspace)
    end
    return nothing
end

"""
    failed!(workspace, job, version, error, backtrace)

Fail the row of `job` and save its message in the cache under `version`, so that the next session
shows the same failure without running the row; a `version` of `nothing` saves nothing. The message
goes to `report_error`, and the status panel of the browser shows the message next to the item. A
source item that fails loses its items.
"""
function failed!(workspace::Workspace, job::Job, at::Union{Nothing,UInt64}, error, backtrace)::Nothing
    catalog, row = workspace.catalog, job.row
    context = @lock catalog.lock begin
        f, place = catalog[row].f, get(workspace.places, row, nothing)
        subject = place isa String ? "Source item: $place" :
            place isa ItemKey ? "Function: $(function_name(f))\n  Item: $(workspace.tree[place].id)" :
            place isa CollectionKey ? "Function: $(function_name(f))\n  Collection: $(workspace.tree[place].id)" :
            "Computation: $(cachekey(workspace, row))"
        "A computation failed\n  $subject\n  Source: $(DataBrowserAPI.source_description(workspace.source))"
    end
    message = DataBrowserAPI.error_summary(error, backtrace) * "\n\n" * context
    @lock catalog.lock begin
        finish!(catalog, job; failed=true) || return nothing
        workspace.errors[row] = failure_prefix(catalog[row].f) * message
        at === nothing || store_computation_revision!(workspace.cache.db, cachekey(workspace, row), at, Nothing; failure=message)
        place = get(workspace.places, row, nothing)
        place isa String && (remove_items!(workspace, place); collections!(workspace))
        publish!(workspace)
    end
    DataBrowserAPI.report_error(context, error, backtrace)
    return nothing
end

failure_prefix(f)::String = f === read_items ? "could not create items: " : "$(function_name(f)) failed: "

"""
    failure(workspace, row) -> String

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
    call(workspace, row, computation)

Call the function of `computation`, the value of `row`, with the results of its inputs, and record
how long it took and whether it threw.
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
    ## The members of a collection, read together, in a vector of their common type.
    eltype(x) === Input && return identity.(results(workspace, Row[v.row for v in x]))
    return any(v -> v isa Union{Input,Part,Tuple,AbstractVector}, x) ? map(v -> resolved(workspace, v), x) : x
end
resolved(::Workspace, x) = x
resolved(::Workspace, x::Selection) = x

# ## Names and versions
#
# Each row has a name, which is its function with the name of each argument, as `fit(a/1)`, or the
# name that the pipeline gives it, as `read:a.csv`. Each row also has a version, a hash of the name
# of its function, the code revision of the function, the versions of its inputs, and its other
# arguments and settings: the same version means the same result, even in another session. A source
# item contributes its id and its fingerprint, such as the modification time of a file; a source
# item without a fingerprint gives a new version each time, so that it is always read again. The
# cache saves, under the name of each row, the version of its last result, and its error when it
# failed.
#
# The *code revision* of a function, which the version uses, is a hash of the code that the function
# can reach; the workspace keeps it in memory (see "Code changes"). The catalog also gives each row
# a *revision*, a counter that rises when the code, an input or the computation of the row changes,
# so that the workspace drops the result of a job that started before (see
# [`Catalogs.jl`](../Catalogs.md)).
#
# `revision(workspace, computation)` and `revision(workspace, items)` are numbers that a window
# compares to know when to draw again; they follow the revisions of the rows. The cache functions
# `store_computation_revision!` and `recorded_revision` keep and read versions.
#
# When a workspace opens again, a row whose saved version is its current version is current, or
# failed with its saved error, without running. Its metadata is the metadata that the cache saved,
# and its value comes from its store; when the store no longer has it, as a `MemoryStore` after a
# restart, the row runs again when something needs its value.

"""
    cachekey(workspace, row) -> String

The key under which the cache saves the version of a row and its store keeps its result: its
function and the key of each argument, as `fit(a/1)`, or the key that the pipeline gave it.
"""
cachekey(workspace::Workspace, row::Row)::String =
    get!(() -> call_id(workspace.catalog[row], x -> argument_cachekey(workspace, x)), workspace.cachekeys, row)
argument_cachekey(workspace::Workspace, x::Input) = cachekey(workspace, x.row)
argument_cachekey(::Workspace, x::Part) = x.id
argument_cachekey(workspace::Workspace, x::Union{Tuple,AbstractVector}) = "[" * join(map(v -> argument_cachekey(workspace, v), x), ", ") * "]"
argument_cachekey(::Workspace, x::Selection) = argument_id(x)
argument_cachekey(::Workspace, x) = argument_id(x)

"""
    version(workspace, row) -> UInt64

The version of the result that `row` gives now: the same version means the same result, even in
another session. It follows the code of its function, the versions of its inputs, and its other
arguments and settings. The caller holds the catalog lock.
"""
function version(workspace::Workspace, row::Row)::UInt64
    value = workspace.catalog[row]
    signature = Tuple{typeof(value.f),map(x -> argument_type(workspace, x), value.args)...}
    workspace.signatures[row] = signature
    ## Types and symbols hash differently in another session; their names do not.
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
    foldl((seed, row) -> hash(Catalogs.version(workspace.catalog, row), seed), Catalogs.input_rows(x); init=hash(argument_id(x)))
# A source item without a fingerprint may have changed at any time: its result is never the saved
# one.
argument_version(::Workspace, x::AbstractDataSourceItem)::UInt64 =
    fingerprint(x) === nothing ? rand(UInt64) : hash(id(x), hash(repr(fingerprint(x))))
argument_version(::Workspace, x::AbstractCollection)::UInt64 = hash(string(typeof(x)), hash(id(x),
    hash(repr(sort!(collect(metadata_dict(metadata(x))); by=first)))))
argument_version(::Workspace, x)::UInt64 = hash(argument_id(x))

"""
    code!(workspace, signature, f) -> Code

The code that the rows of `signature` run, followed from the roots that [`code_roots`](@ref) gives,
with its code revision. It is computed once for each signature, and again after a code change. The
caller holds the catalog lock.
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
    code_roots(project, signature, f) -> Vector

The functions, methods and types whose code runs when a function is called with the argument
types of `signature`: for the stages of the pipeline, what [`stage_roots`](@ref) gives for the type
they run for; else the function. A callable object that is not a function, such as a fit, runs the
methods that make its type callable, whose parameters include the types of the functions it holds.
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
    recorded(workspace, row, version)

What the cache saved for the result of `row` at `version`, when it can be used now: a failure,
or a result whose metadata the cache saved for an item or a collection; else `nothing`. The caller
holds the catalog lock.
"""
function recorded(workspace::Workspace, row::Row, at::UInt64)
    record = recorded_revision(workspace.cache.db, cachekey(workspace, row))
    (record === nothing || record.revision != at) && return nothing
    place = get(workspace.places, row, nothing)
    ## TODO: a computed item that takes a saved result has no metadata.
    saves = place isa CollectionKey || place isa ItemKey && !isempty(workspace.tree[place].source)
    isempty(record.failure) && saves && !haskey(workspace.saved, cachekey(workspace, row)) && return nothing
    return record
end

"""
    restore!(workspace, row) -> Bool

Give `row` the result that the cache saved for it, when its version is the saved one and its
inputs are current, without a job. Return whether it did. The caller holds the catalog lock.
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
    saved = pop!(workspace.saved, cachekey(workspace, row), nothing)
    if !isempty(record.failure)
        workspace.errors[row] = failure_prefix(workspace.catalog[row].f) * record.failure
    elseif saved !== nothing
        store!(workspace.produced, row.index, saved)
    end
    return nothing
end

# ## Results
#
# A store keeps results under the cache key of their row, so that a row that is current does not run
# again for each task that needs its value. `storage(project, T)` chooses the store for results of
# type `T`: items, or any other Julia value. By default, each result type has its own `MemoryStore`
# of 64 MiB, which removes the least recently used results first, and loses them when Julia exits.
# A project made with DataBrowserRecipes keeps the results of every type in one `DuckDBStore`, a
# file next to the project, so they stay from one session to the next. A project can choose another
# size, or another store:
#
# ```julia
# DataBrowserAPI.storage(::MyProject, ::Type{MyItem}) = MemoryStore(; max_bytes=512 * 1024^2)
# DataBrowserAPI.storage(::MyProject, ::Type{MyFit}) = DuckDBStore(joinpath(@__DIR__, "results.duckdb"))
# ```
#
# A store of `nothing` keeps no results of that type: the row runs again when something needs its
# value. A store receives a copy of each result and gives copies; the docstring of `AbstractStore`
# gives its methods. Four kinds of results never go to a store:
#
# - `nothing`;
# - `ExpandedItems`, the items that reading a source item gives, which wait in memory for their
#   `process` (`keep_expanded!` in [`Pipeline.jl`](Pipeline.md));
# - a `Selection`, which reads the workspace each time something takes an item from it;
# - the result of `view(item, selection)`, the part of an item that a window chose.

"""
    store(workspace, type) -> Union{Nothing,AbstractStore}

The store that the project chooses for results of `type`, asked once for each type. It is `nothing`
for the types of results that never go to a store, `Nothing`, `ExpandedItems` and `Selection`, and
when `storage` gives `nothing`. [`keep!`](@ref) also skips the result of `view`.
"""
function store(workspace::Workspace, type::Type)::Union{Nothing,AbstractStore}
    type <: Union{Nothing,ExpandedItems,Selection} && return nothing
    return @lock workspace.stores_lock get!(workspace.stores, type) do
        Base.invokelatest(DataBrowserAPI.storage, workspace.project, type)
    end
end

"""
    keep!(workspace, row, result)

Save a copy of `result` in the store of its type, under the name of `row`. The result of
`view(item, selection)` is not saved: it is made again when needed, and another copy of the item
would push other results out.
"""
function keep!(workspace::Workspace, row::Row, output)::Nothing
    catalog = workspace.catalog
    key, again = @lock catalog.lock (cachekey(workspace, row), catalog[row].f === view)
    again && return nothing
    place = store(workspace, typeof(output))
    ## `deepcopy` is a dynamic call: a method of a package loaded later then does not invalidate this code.
    place === nothing || write(place, key, Base.invokelatest(deepcopy, output))
    return nothing
end

"""
    results(workspace, rows) -> Vector{Any}

The results of `rows`, which are current: from memory, from their stores, read together for each
type, or else computed again with [`computed!`](@ref).
"""
function results(workspace::Workspace, rows::Vector{Row})::Vector{Any}
    found = kept(workspace, rows)
    return Any[value === nothing ? computed!(workspace, row) : something(value) for (row, value) in zip(rows, found)]
end

"""
    kept(workspace, rows) -> Vector{Union{Nothing,Some}}

The results of `rows` that memory or a store still has, as `Some(result)`, and `nothing` for each
result that must be computed again.
"""
function kept(workspace::Workspace, rows::Vector{Row})::Vector{Union{Nothing,Some}}
    catalog = workspace.catalog
    found = Vector{Union{Nothing,Some}}(nothing, length(rows))
    by_type = Dict{Type,Vector{Int}}()
    cachekeys = @lock catalog.lock map(enumerate(rows)) do (position, row)
        given = get(workspace.expanded, row, nothing)
        type = Catalogs.result_type(catalog, row)
        if given !== nothing
            found[position] = Some(first(given))
        elseif type === Nothing
            found[position] = Some(nothing)
        else
            push!(get!(Vector{Int}, by_type, type), position)
        end
        cachekey(workspace, row)
    end
    for (type, positions) in by_type
        place = store(workspace, type)
        place === nothing && continue
        for (position, value) in zip(positions, read(place, type, cachekeys[positions]))
            value === nothing || (found[position] = Some(value))
        end
    end
    return found
end

"""
    computed!(workspace, row)

Compute the result of a current row again, once for all the tasks that ask for it at the same
time, and keep it. The row stays current: it ran before with the same version, and its store had
dropped the result.
"""
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
    publish!(workspace)

Delete the results in the stores and the records in the cache of the rows that were removed, forget
what the workspace kept in memory for the rows that lost their result, and wake the tasks that wait
for the workspace, and the browser. The caller holds the catalog lock.
"""
function publish!(workspace::Workspace)::Nothing
    catalog = workspace.catalog
    for row in lost!(catalog)
        forget_expanded!(workspace, row)
        delete!(workspace.executions, row)
        delete!(workspace.errors, row)
        Catalogs.state(catalog, row) == Catalogs.REMOVED || continue
        key = pop!(workspace.cachekeys, row, nothing)
        if key !== nothing
            type = Catalogs.result_type(catalog, row)
            place = store(workspace, type)
            place === nothing || delete!(place, type, key)
            delete_computation_revision!(workspace.cache.db, key)
        end
        delete!(workspace.produced, row.index)
        foreach(found -> delete!(found, row), (workspace.places, workspace.signatures, workspace.row_locks, workspace.evaluated))
    end
    ## Wakes the tasks that wait for the scan or for the workspace to be idle.
    notify(catalog.changed)
    changed!(workspace)
    return nothing
end

# ## Code changes
#
# Each signature of a row, its function and the types of its arguments, has a code revision: a
# content hash of the code it can reach from its roots ([`CodeRevisions.jl`](../CodeRevisions.md)).
# The roots of a row of the pipeline are `stage_roots(project, stage, type)`, which for a Recipes
# project are its registered callbacks. The roots of any other row are its function. A callable
# object that is not a function, such as a fit, has as roots its type and the methods that make the
# type callable: the parameters of the type include the types of the functions it holds, such as the
# curve of the fit. The workspace follows the code only into `Main` and into packages developed from
# a local folder (`Pkg.develop`); for every other package, the Julia version and the Manifest count
# instead.
#
# The version of each result includes the revision of its code. Twice a second, the workspace asks
# Revise to load saved edits, including files tracked with `includet`, even when the REPL is idle.
# After a method definition, or when the roots differ, the workspace computes the code revision
# again; `evaluate` does the same check first when a method was defined since the last check. When
# the revision changed, the rows of that signature become stale, and with them every row that reads
# them: source items are read again, as if the source had changed them, and items and collections
# are processed again when a window shows them or a script reads them, or in the background with
# `background_processing=true`. Collections ask `has_stage` again, so a collection `process` defined
# later gets its rows. The same code defined again, as when a script runs again, changes nothing.
#
# While a browser is open, the keyboard focus of its main window controls these checks: an inactive
# window pauses them, and gaining focus resumes them. Without a browser, including after closing
# one, the workspace keeps checking.
#
# The revision does not see a mutable value changed in place, nor a change to a macro: the functions
# that use a macro keep their old expansion until they are defined again. The workspace warns about
# code that it cannot follow: a non-constant global, a call through `eval`, `invokelatest` or a
# computed name, a generated function, and a value it cannot read. The warning shows the way from
# the root to it.

"""
    check_code!(workspace)

Make the rows whose code changed stale, so that they are computed again. The code revision of a
signature is computed again only when a method was defined since the last check, or when
[`code_roots`](@ref) gives other roots. Collections ask `has_stage` again, since a collection
`process` or member `process` methods may be defined now, or no longer.
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
            ## The collections of computed values belong to the workspace: the project never processes them.
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
#
# Scripts and windows ask the workspace for results with computations:
#
# ```julia
# item = only(materialize_items(workspace, ["a/1"]))
# fitted = evaluate(workspace, Computation(fit, item))
# ```
#
# `fit` is a function of your own. `evaluate` adds the computation as a row, keeps the row until the
# workspace closes, runs it ahead of background work, and waits for its result. An item of the
# workspace among the arguments stands for the row of its latest value, so the next `evaluate`
# computes it again after that item changed:
#
# ```text
#   Computation(fit, item)  ──bound──▶  fit(the row of the latest value of a/1)
# ```
#
# A `Computation` is also an item whose data is its result, so a `Selection` can hold computations,
# as the values that a visualizer passes through a function. `computation(workspace, item)` gives
# the computation of the latest value of an item. In the browser, a visualizer draws again when the
# `revision` of what it shows changes.
#
# Give computations named functions. An anonymous function has a generated name, such as `#3`,
# which can change from one session to the next: its result is then computed again, and its
# computed item gets another id.
#
# TODO: a way to let go of the rows that `evaluate` keeps; each computation stays, with its result,
# until the workspace closes.

"""
    bound(workspace, computation) -> Computation

`computation` with each data item among its arguments that is an item of the workspace replaced by the
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
function Catalogs.input_rows(selection::Selection)::Vector{Row}
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
keeps, and kept for later calls of `evaluate`. The workspace keeps the computation until it closes.
A failed computation, or one whose input failed, throws its error.
"""
function evaluate(workspace::Workspace, value::Computation)
    catalog = workspace.catalog
    ## Code defined since the last check makes its results stale before this one is read.
    world = Base.get_world_counter()
    @lock(catalog.lock, any(code -> code.world != world, values(workspace.code))) && Base.invokelatest(check_code!, workspace)
    row = @lock catalog.lock begin
        row = add!(catalog, bound(workspace, value))
        row in workspace.evaluated || (hold!(catalog, row); push!(workspace.evaluated, row))
        restore!(workspace, row)
        row
    end
    wait(catalog, row, VIEWED_ITEM) == Catalogs.CURRENT || error(failure(workspace, row))
    return only(results(workspace, [row]))
end

"""
    computation(workspace, item) -> Computation

The computation that gives the latest value of an item, given as a key, a public id or a data item:
its member `process`, when the collections above it have member `process` methods, or else its own
`process`. Its [`inputs`](@ref) lead back to the source item it comes from. `computation` gives the
computation without running it.
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

The computation that gives one item of a selection, without loading its data.
"""
function computation(selection::Selection, index::Integer)::Computation
    data = selection.data::ItemData
    item = getfield(data, :items)[index]
    return item isa Computation ? item : computation(getfield(data, :workspace), item)
end

# The row of a computation, or `nothing` when the workspace does not have it. The catalog stays as
# it is.
function row(workspace::Workspace, value::Computation)::Union{Nothing,Row}
    found = @lock workspace.catalog.lock get(workspace.catalog, bound(workspace, value), Catalogs.NOWHERE)
    return found == Catalogs.NOWHERE ? nothing : found
end

# The time of an execution covers the call of the function, with compilation and waits, and not the
# evaluation of its inputs or the storage of its result.
# The method of `DataBrowserAPI.last_execution` for a workspace.
function last_execution(workspace::Workspace, value::Computation)::Union{Nothing,ComputationExecution}
    found = row(workspace, value)
    found === nothing && return nothing
    @lock workspace.catalog.lock Catalogs.state(workspace.catalog, found) in (Catalogs.CURRENT, Catalogs.FAILED) ?
        get(workspace.executions, found, nothing) : nothing
end

# The method of `DataBrowserAPI.cache_info` for a workspace: whether the store of its type has the
# result of a current computation, and its size.
function cache_info(workspace::Workspace, value::Computation)
    found, catalog = row(workspace, value), workspace.catalog
    found === nothing && return (cached=false, bytes=nothing)
    type, key, current = @lock catalog.lock (Catalogs.result_type(catalog, found), cachekey(workspace, found),
        Catalogs.state(catalog, found) == Catalogs.CURRENT)
    place = store(workspace, type)
    (current && place !== nothing && haskey(place, type, key)) || return (cached=false, bytes=nothing)
    return (cached=true, bytes=DataBrowserAPI.stored_size(place, type, key))
end

"""
    revision(workspace, computation) -> UInt

A number that changes when the result of `computation` changes: when it becomes current, or stops
being so. A window keeps the number it drew with, and draws again when it differs. Reading it
computes nothing.
"""
function revision(workspace::Workspace, value::Computation)::UInt
    found, catalog = row(workspace, value), workspace.catalog
    found === nothing && return UInt(0)
    return @lock catalog.lock hash(found.index, hash(Catalogs.state(catalog, found) == Catalogs.CURRENT, hash(Catalogs.revision(catalog, found))))
end

"""
    CURRENT_WORKSPACE

The workspace from which `data(c)` and `metadata(c)` of a `Computation` read results, so that code
that receives only a computation, such as a visualizer, needs no workspace. When it is `nothing`,
`data(c)` calls the function and its inputs directly, without reading the stores.

```julia
with(CURRENT_WORKSPACE => workspace) do
    data(Computation(fit, item))
end
```
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
# item it reads, with the metadata of its result on top when that is an item: `fit(a/1)` has the
# metadata of `a/1`, and the metadata of the fit when it returns an item.
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

# ## Computed items
#
# `push!(workspace, computation)` adds a computation as an item of the tree, computed in the
# background like the items of the source. Its collection has the name of its function, below the
# collection `Computed`:
#
# ```text
#   Computed
#   └── fit
#       └── fit(a/1)
# ```
#
# `delete!(workspace, id)` removes it, and `results(workspace, ids)` gives the results of computed
# items.

# The name of the function of computed values: the name of the collection that holds them, and the
# start of their ids. A package whose computations are values of its own type gives them a name, and
# can give their values their own `id` and `label`. TODO: an anonymous function gets its generated
# name, such as `#3`, which changes from session to session; make its name from the content of its
# code (docs/plans/processing.md).
function_name(f) = string(nameof(f))

id(value::Computation) = call_id(value, argument_id)
# The function, then each argument as `name` writes it, then the settings.
call_id(value::Computation, name) = string(function_name(value.f), "(",
    join(map(name, value.args), ", "),
    isempty(value.settings) ? "" : "; " * join(("$name = $(repr(setting))" for (name, setting) in pairs(value.settings)), ", "),
    ")")
# TODO: the id of a computation repeats the ids of its inputs, so that the id of a member `process`
# contains the id of every member of the collection.
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
with the name of the function.
"""
struct ComputedCollection <: AbstractCollection
    name::String
end
id(collection::ComputedCollection) = collection.name
label(collection::ComputedCollection) = collection.name

const COMPUTED = ComputedCollection("Computed")

# TODO: a rule for when the workspace drops a computed item. Today it keeps each one until it
# closes, even when nothing uses it any more.
"""
    push!(workspace, computation) -> Workspace

Add `computation` to the workspace as an item, computed in the background once the items it reads
are processed, even without `background_processing`: the rows that it reads inherit its priority. It is an item of the collection of its function, below the collection `Computed`.
The data items among its arguments that are items of the workspace are read in their latest value.
A new computation with the id of one added before replaces the older one, and runs again when it
reads other rows, as when the latest value of an argument moved from its own row to its member row.

"""
function Base.push!(workspace::Workspace, value::Computation)::Workspace
    catalog, tree = workspace.catalog, workspace.tree
    @lock catalog.lock begin
        given = bound(workspace, value)
        known = get(tree.item_ids, id(value), nothing)
        if known !== nothing
            isempty(tree[known].source) || error("The workspace has an item with the id \"$(id(value))\" from its source")
            row = tree[known].row
            reads = unique!(Catalogs.input_rows(Catalogs.instanced(catalog, given; add=false).args))
            reads == Catalogs.inputs(catalog, row) || (replace!(catalog, row, given); publish!(workspace))
            return workspace
        end
        holder = collection!(tree, collection!(tree, ROOT, COMPUTED, Dict{Symbol,Any}()),
            ComputedCollection(function_name(value.f)), Dict{Symbol,Any}())
        key = item!(tree, id(value), label(value), typeof(value), holder, "", Dict{Symbol,Any}())
        row = add!(catalog, given)
        hold!(catalog, row)
        ## A row of the pipeline keeps the item it gives.
        tree[key].row = row
        get!(workspace.places, row, key)
        get!(workspace.cachekeys, row, id(value))
        want!(catalog, row, BACKGROUND_ITEM)
        restore!(workspace, row)
        publish!(workspace)
    end
    return workspace
end

"""
    delete!(workspace, id) -> Workspace

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
    results(workspace, ids) -> Vector

The results of the computed items with `ids`, as their functions returned them. Items that are not
computed yet are computed now, and `results` waits for them.
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
comes with its latest value: the one its member `process` returned, when that is current, or else
its own processed data. A computed item is its computation, whose data is its result.

An item that is not processed yet is processed now, ahead of background work, and `materialize_items`
waits for it. The member `process` of each item is requested too, without waiting for it: a later
`materialize_items` gives the later value once it is ready. A failed item throws its error.

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

# Ask for the items ahead of background work: their own `process`, or the source item that they
# wait for, and their member `process`. A request ends when its row has a result, so the callers ask
# again for an item that waited for its source item.
function Catalogs.request!(workspace::Workspace, keys::Vector{ItemKey})::Nothing
    catalog = workspace.catalog
    @lock catalog.lock for key in keys
        item = workspace.tree[key]
        if item.row === nothing
            source = get(workspace.sources, item.source, nothing)
            source === nothing || request!(catalog, source, VIEWED_ITEM)
        else
            request!(catalog, item.row, VIEWED_ITEM)
        end
        item.member === nothing || request!(catalog, item.member, VIEWED_COLLECTION)
    end
    return nothing
end

"""
    processed(workspace, items) -> Bool

Ask for `items` ahead of background work, as `materialize_items` does, and tell whether every item
is processed now, or failed. The call does not wait, so a window can keep showing what it showed until
the items are ready.
"""
function processed(workspace::Workspace, keys::Vector{ItemKey})::Bool
    catalog = workspace.catalog
    @lock catalog.lock begin
        request!(workspace, keys)
        return catalog.closed || all(keys) do key
            row = workspace.tree[key].row
            row !== nothing && (Catalogs.state(catalog, row) in (Catalogs.CURRENT, Catalogs.FAILED) || Catalogs.stuck(catalog, row))
        end
    end
end

"""
    wait_processed(workspace, items) -> UInt

Ask for `items` ahead of background work, wait until each is processed, and return their
[`revision`](@ref). A failed item throws its error.
"""
function wait_processed(workspace::Workspace, keys::Vector{ItemKey})::UInt
    catalog = workspace.catalog
    @lock catalog.lock begin
        request!(workspace, keys)
        for key in keys
            item = workspace.tree[key]
            ## The rows of the item can be new, or stale again, since the request above.
            request!(workspace, [key])
            while item.row === nothing && !item.removed && !catalog.closed
                wait(catalog.changed)
                request!(workspace, [key])
            end
            state = item.row === nothing ? Catalogs.REMOVED : wait(catalog, item.row, VIEWED_ITEM)
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

A number that changes when `materialize_items` would deliver other values of `items`: an item was
processed again, or its member `process` became current or stopped being so. A window keeps the
number it drew with, and draws again when it differs.
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
added or is removed. All workspaces of the Julia session share it, so it may also rise for a change
in another workspace. Items are added and removed only together with such a change. While the number
stays the same, so do the [`revision`](@ref) of any items and the item of each public id.
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
        row === nothing || request!(catalog, row, VIEWED_ITEM)
    end
    return nothing
end

"""
    unread(workspace) -> Vector{String}

The public ids of the source items that the source has and the workspace has not read yet: their
items are not in the workspace. A source item that failed is not included. For a directory source,
an id is the path of a file below the source root.

[`read_first!`](@ref) reads chosen source items ahead of the others.
"""
unread(workspace::Workspace)::Vector{String} = @lock workspace.catalog.lock String[
    id for (id, row) in workspace.sources if Catalogs.state(workspace.catalog, row) in (Catalogs.MISSING, Catalogs.STALE)]

"""
    work_counts(workspace) -> (completed, total, running)

The jobs that ended, all jobs (ended, running and waiting), and the jobs that run now. The
performance window of the browser shows them.
"""
work_counts(workspace::Workspace)::Tuple{Int,Int,Int} = @lock workspace.catalog.lock (
    workspace.completed, workspace.completed + workspace.running + queued(workspace.catalog), workspace.running)
