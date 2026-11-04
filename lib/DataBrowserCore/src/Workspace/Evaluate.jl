# A computation, `Computation(f, args...; settings...)`, is a function call before it runs: reading
# one source item, the `process` of one item, or a function of your own, such as a fit. The
# workspace keeps each computation in a row of its *catalog*, a table, with the state of the
# computation: missing, stale, current or failed ([`Catalogs.jl`](../Catalogs.md)). To compute a
# row, the workspace runs a *job*.
#
# The workspace adds a row for each call of the project's code ([`Pipeline.jl`](Pipeline.md)), and
# one row for each computation that a script or a window asks for:
#
# | Row            | Calls                                  |
# |:---------------|:---------------------------------------|
# | read           | `read(project, source, source_item)`   |
# | process        | `process(project, value)`              |
# | group process  | `process(project, group, members)`     |
# | member process | `process(project, member, group)`      |
#
# Windows show the *latest version* of a value: the value of that id that the last of these rows
# gives.
#
# Scripts ask for results with these functions:
#
# | Call                                | Gives                                  | Waits | Keeps in the workspace          |
# |:------------------------------------|:---------------------------------------|:------|:--------------------------------|
# | `materialize_items(workspace, ids)` | the latest version of each value       | yes   | nothing new                     |
# | `evaluate(workspace, computation)`  | the result of a computation            | yes   | its row, until the workspace closes |
#
# Three parts of the workspace keep information about a row:
#
# ```text
#     catalog, in memory          the state of each row, its inputs and its priority
#     cache, a DuckDB file        for each row, by its key: the version of its last result, or its
#                                 error; and for a row of the pipeline, the values it gives, with
#                                 their metadata and labels. The next session knows from it which
#                                 rows are current, and has their values without running them
#     stores, one for each        for each row, by its key: its result. A MemoryStore, the default,
#       type of result            loses the results when Julia exits; a DuckDBStore, as a project
#                                 made with DataBrowserRecipes uses, keeps them in a file
# ```
#
# The key of a row is its position in the catalog. The cache keeps the key of each computation by
# its id (see "Names and versions"), so that the computation gets the same key in the next session.
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
#                          finished!: the pipeline adds the rows that the values of the result need
#
#     finish! belongs to the catalog: it ends the job and sets the state of the row.
#     finished! belongs to the pipeline: it adds rows, such as the process of each new value.
# ```
#
# The version of a row identifies its result (see "Names and versions"). A current row whose store
# no longer has its result runs again when something needs the result.

# ## Workers
#
# Worker tasks run the jobs: one for each Julia thread, and at least two. Jobs run in this order of
# priority, highest first:
#
# 1. what a window shows and what a script asks for: its values and computations (`VIEWED_ITEM`);
# 2. source items (`SOURCES_FIRST`);
# 3. the `process` methods, in the background (`BACKGROUND_ITEM`).
#
# By default, `open_workspace` sets `background_processing=false`: the workers read every source
# item, but run a `process` method only when a window or a script asks for its value.
#
# A `read` or a `process` must return a data item, or a vector of data items; any other result
# fails the row. When a function throws, the row fails: the error is logged, the status panel of the
# browser shows the error next to its value, and the cache saves it. When reading a source item
# fails, its values leave the workspace until a later read succeeds. A `process` that fails gives
# no values, and the value it was given keeps the failed row as its latest version, until the row
# runs again. A failed row does not run again, even in a later session, until its version changes:
# its code, an input or an argument changed. To run failed rows again without a change, open the
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

Compute the row of `job`, keep its result, and add the rows that its values need. A row whose
current version is the one the cache saved becomes current, or failed, without running. A result of
the wrong type fails the row: a `read` or a `process` must return an `AbstractDataItem`, or a vector
of them.
"""
function run!(workspace::Workspace, job::Job)::Nothing
    catalog, row = workspace.catalog, job.row
    ## Until `finish!` ends the job, every error fails the row, so that no row stays running without
    ## a job. The cache saves only the error of the function, under the version of the row: after
    ## any other error, the next session runs the row again.
    value, pipeline, at, record = try
        @lock catalog.lock begin
            at = version(workspace, row)
            catalog[row], haskey(workspace.stages, row), at, recorded(workspace, row, at)
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
    given = output isa AbstractVector ? output : [output]
    pipeline && !all(x -> x isa AbstractDataItem, given) && return failed!(workspace, job, at,
        ErrorException("$(function_name(value.f)) returned a $(typeof(output)), not an item or a vector of items"), backtrace())
    ## The ids, labels, members and metadata of the values are the project's code, which runs
    ## outside the lock.
    outputs = try
        keepable(catalog, job) && keep!(workspace, row, output)
        pipeline ? [(Output(id(x), typeof(x), label(workspace.project, x), x isa AbstractGroup ? members(x) : nothing,
            output_key!(workspace.cache.db, row.index, id(x))), metadata_dict(metadata(x))) for x in given] : nothing
    catch error
        return failed!(workspace, job, nothing, error, catch_backtrace())
    end
    @lock catalog.lock begin
        finish!(catalog, job; version=at, type=typeof(output)) || return nothing
        delete!(workspace.errors, row)
        store_computation_revision!(workspace.cache.db, row.index, id(value), at, typeof(output))
        if outputs !== nothing
            finished!(workspace, row, Output[output for (output, _) in outputs])
            ## The cache saves the values that the workspace kept.
            messages = String[]
            for (position, (output, values)) in enumerate(outputs)
                output in get(workspace.outputs, row, Output[]) || continue
                append!(messages, conflict_message.(store!(workspace.produced, output.key, values)))
                append!(messages, store_output!(workspace.cache.db, row.index, Int(workspace.stages[row]), position,
                    (; output.id, output.label, output.type, output.members, metadata=values)))
            end
            conflicts!(workspace, row, unique!(messages))
        end
        publish!(workspace)
    end
    return nothing
end

"""
    failed!(workspace, job, version, error, backtrace)

Fail the row of `job` and save its message in the cache under `version`, so that the next session
shows the same failure without running the row; a `version` of `nothing` saves nothing. The message
goes to `report_error`, and the status panel of the browser shows the message next to the value. A
row of the pipeline that fails gives no values.
"""
function failed!(workspace::Workspace, job::Job, at::Union{Nothing,UInt64}, error, backtrace)::Nothing
    catalog, row = workspace.catalog, job.row
    context = @lock catalog.lock begin
        stage, f = get(workspace.stages, row, nothing), catalog[row].f
        about = stage == SOURCE_READ ? "Source item: $(subject(workspace, row))" :
            stage !== nothing ? "Function: $(function_name(f))\n  Item: $(subject(workspace, row))" :
            "Computation: $(subject(workspace, row))"
        "A computation failed\n  $about\n  Source: $(DataBrowserAPI.source_description(workspace.source))"
    end
    message = DataBrowserAPI.error_summary(error, backtrace) * "\n\n" * context
    @lock catalog.lock begin
        finish!(catalog, job; failed=true) || return nothing
        workspace.errors[row] = "$(function_name(catalog[row].f)) failed: " * message
        at === nothing || store_computation_revision!(workspace.cache.db, row.index, id(catalog[row]), at, Nothing; failure=message)
        haskey(workspace.stages, row) && finished!(workspace, row, nothing)
        publish!(workspace)
    end
    DataBrowserAPI.report_error(context, error, backtrace)
    return nothing
end

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
    args = map(x -> resolved(workspace, row, x), value.args)
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

# The value that a function receives for an argument: an input is the result of its row, a part is
# the value with its id in that result, and the values of members that the row takes are read
# together, in the order of the members.
function resolved(workspace::Workspace, row::Row, ::MemberValues{T}) where {T}
    catalog = workspace.catalog
    taken = @lock catalog.lock filter!(((x, at),) -> output(workspace, at, x) !== nothing, member_values(workspace, row))
    return T[pick(result, x) for ((x, _), result) in zip(taken, results(workspace, last.(taken)))]
end
resolved(workspace::Workspace, ::Row, x) = resolved(workspace, x)
resolved(workspace::Workspace, x::Input) = only(results(workspace, [x.row]))
resolved(workspace::Workspace, x::Part) = pick(resolved(workspace, x.of), x.id)
resolved(workspace::Workspace, x::Tuple) = map(v -> resolved(workspace, v), x)
function resolved(workspace::Workspace, x::AbstractVector)
    ## Results of rows, read together, in a vector of their common type.
    eltype(x) === Input && return identity.(results(workspace, Row[v.row for v in x]))
    return any(v -> v isa Union{Input,Part,Tuple,AbstractVector}, x) ? map(v -> resolved(workspace, v), x) : x
end
resolved(::Workspace, x) = x
resolved(::Workspace, x::Selection) = x

# ## Names and versions
#
# The computation of each row has an id, which is its function with the id of each argument, as
# `fit(a/1)`. Each row also has a version, a hash of the name of its function, the code revision of
# the function, the versions of its inputs, and its other arguments and settings: the same version
# means the same result, even in another session. A source item contributes its id and its
# fingerprint, such as the modification time of a file; a source item without a fingerprint gives a
# new version each time, so that it is always read again. The cache saves, under the key of each
# row, the id of its computation, the version of its last result, and its error when it failed. The
# next session gives the key to the first row whose computation has that id.
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
        seed = hash(argument_version(workspace, row, x), seed)
    end
    return hash(repr(value.settings), seed)
end

argument_type(workspace::Workspace, x::Input) = Catalogs.result_type(workspace.catalog, x.row)
function argument_type(workspace::Workspace, x::Part)
    found = output(workspace, x.of.row, x.id)
    return found === nothing ? Any : found.type
end
argument_type(::Workspace, ::MemberValues{T}) where {T} = Vector{T}
argument_type(::Workspace, x) = typeof(x)

# The values of members count as the sum of a hash of the id and the version of each, which the
# workspace keeps as they change (see `input!`).
argument_version(workspace::Workspace, row::Row, ::MemberValues)::UInt64 = workspace.taken[row].version
argument_version(workspace::Workspace, ::Row, x)::UInt64 = argument_version(workspace, x)
argument_version(workspace::Workspace, x::Input)::UInt64 = Catalogs.version(workspace.catalog, x.row)
argument_version(workspace::Workspace, x::Part)::UInt64 = hash(x.id, argument_version(workspace, x.of))
argument_version(workspace::Workspace, x::Union{Tuple,AbstractVector{<:Union{Input,Part}}})::UInt64 =
    foldl((seed, v) -> hash(argument_version(workspace, v), seed), x; init=UInt64(0))
argument_version(workspace::Workspace, x::Selection)::UInt64 =
    foldl((seed, row) -> hash(Catalogs.version(workspace.catalog, row), seed), Catalogs.input_rows(x); init=hash(argument_id(x)))
# A source item without a fingerprint may have changed at any time: its result is never the saved
# one.
argument_version(::Workspace, x::AbstractDataSourceItem)::UInt64 =
    fingerprint(x) === nothing ? rand(UInt64) : hash(id(x), hash(repr(fingerprint(x))))
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

stage(::Type{<:Tuple{typeof(read),Any,Any,S}}) where {S} = (SOURCE_READ, S)
stage(::Type{<:Tuple{typeof(read),Any,Any,S,Any}}) where {S} = (SOURCE_READ, S)
stage(::Type{<:Tuple{typeof(process),Any,I}}) where {I} = (ITEM_PROCESS, I)
stage(::Type{<:Tuple{typeof(process),Any,G,AbstractVector}}) where {G} = (GROUP_PROCESS, G)
stage(::Type{<:Tuple{typeof(process),Any,M,G}}) where {M,G} = (MEMBER_PROCESS, G)
stage(_) = nothing

"""
    recorded(workspace, row, version)

What the cache saved for the result of `row` at `version`, when it can be used now: a failure, or a
result, and for a row of the pipeline the values it gave; else `nothing`. The caller holds the
catalog lock.
"""
function recorded(workspace::Workspace, row::Row, at::UInt64)
    record = recorded_revision(workspace.cache.db, row.index)
    (record === nothing || record.revision != at) && return nothing
    # TODO: a row of the pipeline that gave no values has nothing saved, so it runs again in each
    # session.
    isempty(record.failure) && haskey(workspace.stages, row) && !haskey(workspace.saved, row.index) && return nothing
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

# The values and the metadata of a row, or its error, as the cache saved them.
function restored!(workspace::Workspace, row::Row, record)::Nothing
    saved = pop!(workspace.saved, row.index, SavedOutput[])
    failed = !isempty(record.failure)
    failed && (workspace.errors[row] = "$(function_name(workspace.catalog[row].f)) failed: " * record.failure)
    haskey(workspace.stages, row) || return nothing
    outputs = [Output(value.id, value.type, value.label, value.members, output_key!(workspace.cache.db, row.index, value.id)) for value in saved]
    finished!(workspace, row, failed ? nothing : outputs)
    for (output, value) in zip(outputs, saved)
        output in get(workspace.outputs, row, Output[]) && store!(workspace.produced, output.key, value.metadata)
    end
    return nothing
end

# ## Results
#
# A store keeps results under the key of their row, so that a row that is current does not run
# again for each task that needs its value. Each value of a vector that a row of the pipeline gives
# goes to the store of its own type, under the key that the cache gives the value. `storage(project, T)`
# chooses the store for results of type `T`: items, or any other Julia value. By default, each
# result type has its own `MemoryStore` of 64 MiB, which removes the least recently used results
# first, and loses them when Julia exits.
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
# gives its methods. Three kinds of results never go to a store:
#
# - `nothing`;
# - a `Selection`, which reads the workspace each time something takes an item from it;
# - the result of `view(item, selection)`, the part of an item that a window chose.

"""
    store(workspace, type) -> Union{Nothing,AbstractStore}

The store that the project chooses for results of `type`, asked once for each type. It is `nothing`
for the types of results that never go to a store, `Nothing` and `Selection`, and when `storage`
gives `nothing`. [`keep!`](@ref) also skips the result of `view`.
"""
function store(workspace::Workspace, type::Type)::Union{Nothing,AbstractStore}
    type <: Union{Nothing,Selection} && return nothing
    return @lock workspace.stores_lock get!(workspace.stores, type) do
        Base.invokelatest(DataBrowserAPI.storage, workspace.project, type)
    end
end

"""
    keep!(workspace, row, result)

Save a copy of `result` in the store of its type, under the key of `row`. A vector that a row of
the pipeline gives is saved as its values, each in the store of its own type. The result of
`view(item, selection)`, and one value picked from the result of another row, is not saved: it is
made again when needed, and another copy of the item would push other results out.
"""
function keep!(workspace::Workspace, row::Row, output)::Nothing
    catalog = workspace.catalog
    again, pipeline = @lock catalog.lock (catalog[row].f in (view, pick), haskey(workspace.stages, row))
    again && return nothing
    for (key, x) in (pipeline && output isa AbstractVector ? [(output_key!(workspace.cache.db, row.index, id(x)), x) for x in output] : [(row.index, output)])
        place = store(workspace, typeof(x))
        ## `deepcopy` is a dynamic call: a method of a package loaded later then does not invalidate this code.
        place === nothing || write(place, key, Base.invokelatest(deepcopy, x))
    end
    return nothing
end

"""
    results(workspace, rows) -> Vector{Any}

The results of `rows`, which are current: from their stores, read together for each type, or else
computed again with [`computed!`](@ref).
"""
function results(workspace::Workspace, rows::Vector{Row})::Vector{Any}
    found = kept(workspace, rows)
    return Any[value === nothing ? computed!(workspace, row) : something(value) for (row, value) in zip(rows, found)]
end

"""
    kept(workspace, rows) -> Vector{Union{Nothing,Some}}

The results of `rows` that a store still has, as `Some(result)`, and `nothing` for each result that
must be computed again. A vector that a row of the pipeline gives is read from the stores of its
values, and must be computed again when one of them is missing. The results that `keep!` does not
save are always computed again: under their key, a store can only have the result of another row
that had the key in an earlier session.
"""
## TODO: a row whose result was never saved in the session that recorded it (no store then, or Julia
## stopped first) can still read the result of another row that had its key in an earlier session.
function kept(workspace::Workspace, rows::Vector{Row})::Vector{Union{Nothing,Some}}
    catalog = workspace.catalog
    ## Each result as the type and the key of each part that a store keeps: the result, or each value
    ## of a vector that a row of the pipeline gives.
    unsaved, vectors, parts = @lock catalog.lock begin
        types = [Catalogs.result_type(catalog, row) for row in rows]
        vectors = [type <: AbstractVector && haskey(workspace.stages, row) for (row, type) in zip(rows, types)]
        [catalog[row].f in (view, pick) for row in rows], vectors,
            [vector ? [(output.type, output.key) for output in get(workspace.outputs, row, Output[])] :
            [(type, Int64(row.index))] for (row, type, vector) in zip(rows, types, vectors)]
    end
    found = [Vector{Union{Nothing,Some}}(nothing, length(part)) for part in parts]
    by_type = Dict{Type,Vector{Tuple{Int,Int}}}()
    for (position, part) in enumerate(parts), (index, (type, _)) in enumerate(part)
        type === Nothing ? (found[position][index] = Some(nothing)) : push!(get!(Vector{Tuple{Int,Int}}, by_type, type), (position, index))
    end
    for (type, places) in by_type
        place = store(workspace, type)
        place === nothing && continue
        for ((position, index), value) in zip(places, read(place, type, [parts[position][index][2] for (position, index) in places]))
            value === nothing || (found[position][index] = Some(value))
        end
    end
    return Union{Nothing,Some}[again || any(isnothing, values) ? nothing : vector ? Some(identity.(something.(values))) : only(values)
        for (values, vector, again) in zip(found, vectors, unsaved)]
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
        @lock catalog.lock Catalogs.revision(catalog, row) == before || return output
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
        delete!(workspace.executions, row)
        delete!(workspace.errors, row)
        Catalogs.state(catalog, row) == Catalogs.REMOVED || continue
        type = Catalogs.result_type(catalog, row)
        place = store(workspace, type)
        place === nothing || delete!(place, type, row.index)
        delete_computation_revision!(workspace.cache.db, row.index)
        foreach(found -> delete!(found, row), (workspace.outputs, workspace.signatures, workspace.row_locks, workspace.evaluated))
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
# them: source items are read again, as if the source had changed them, and items are processed
# again when a window shows them or a script reads them, or in the background with
# `background_processing=true`. The same code defined again, as when a script runs again, changes
# nothing.
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

Make the rows whose code changed stale, so that they are computed again, and add or release the
rows of the pipeline whose methods apply now, or no longer apply. The code revision of a signature
is computed again only when a method was defined since the last check, or when
[`code_roots`](@ref) gives other roots.
"""
function check_code!(workspace::Workspace)::Nothing
    catalog = workspace.catalog
    known, asked = @lock catalog.lock (copy(workspace.code), copy(workspace.methods))
    world = Base.get_world_counter()
    current = Dict{Type,Code}()
    for (signature, code) in known
        roots = code_roots(workspace.project, signature, code.f)
        code.world == world && isequal(code.roots, roots) && continue
        current[signature] = Code(code.f, roots, world, code_revision(roots))
        warn_untracked(signature, current[signature], code)
    end
    isempty(current) && return nothing
    answers = Dict{Tuple,Any}(question => first(question)(Base.tail(question)...) for question in keys(asked))
    @lock catalog.lock begin
        workspace.closed && return nothing
        ## Every value, group and source item with members is checked again when a method applies
        ## now that did not, or the other way around.
        if !isequal(answers, asked)
            workspace.methods = answers
            refresh!(workspace, collect(keys(workspace.versions)))
            for row in collect(values(workspace.sources))
                value = catalog[row]
                length(value.args) == 4 && source!(workspace, value.args[3])
            end
        end
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
# workspace closes, runs it ahead of background work, and waits for its result. A value of the
# workspace among the arguments stands for its latest version, so the next `evaluate` computes it
# again after that value changed:
#
# ```text
#   Computation(fit, item)  ──bound──▶  fit(the value a/1 of the row of its latest version)
# ```
#
# A `Selection` can hold computations, as the values that a visualizer passes through a function:
# the data of each is its result. `computation(workspace, id)` gives the computation of the latest
# version of a value. In the browser, a visualizer draws again when the `revision` of what it shows
# changes.
#
# Give computations named functions. An anonymous function has a generated name, such as `#3`,
# which can change from one session to the next: its result is then computed again.
#
# TODO: a way to let go of the rows that `evaluate` keeps; each computation stays, with its result,
# until the workspace closes.

"""
    bound(workspace, computation) -> Computation

`computation` with each data item among its arguments that is a value of the workspace replaced by
its latest version, so that it follows the changes of that value. The caller holds the catalog
lock.
"""
bound(workspace::Workspace, value::Computation) =
    Computation(value.f, map(x -> bound_argument(workspace, x), value.args), value.settings)
bound_argument(workspace::Workspace, x::Computation) = bound(workspace, x)
function bound_argument(workspace::Workspace, x::AbstractDataItem)
    rows = get(workspace.versions, id(x), nothing)
    return rows === nothing ? x : Part(Input(workspace.catalog, rows[end]), id(x))
end
bound_argument(workspace::Workspace, x::Tuple) = map(v -> bound_argument(workspace, v), x)
bound_argument(workspace::Workspace, x::AbstractVector) =
    any(v -> v isa AbstractDataItem, x) ? map(v -> bound_argument(workspace, v), x) : x
bound_argument(::Workspace, x::Selection) = x
bound_argument(::Workspace, x) = x

# A selection reads the latest version of each of its values, and the result of each of its
# computations.
function Catalogs.input_rows(selection::Selection)::Vector{Row}
    data = selection.data::ItemData
    workspace = getfield(data, :workspace)
    found = Row[]
    for x in getfield(data, :items)
        row = x isa String ? last(get(workspace.versions, x, [Catalogs.NOWHERE])) :
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
    computation(workspace, id) -> Computation

The computation that gives the latest version of a value, given as its id or as a data item: the
`read` or the `process` of the project that gave it. Its result can hold other values too. Its
[`inputs`](@ref) lead back to the source item the value comes from. `computation` gives the
computation without running it.
"""
function computation(workspace::Workspace, value::Union{AbstractString,AbstractDataItem})::Computation
    x = value isa AbstractDataItem ? id(value) : String(value)
    @lock workspace.catalog.lock begin
        rows = get(workspace.versions, x, nothing)
        rows === nothing && error("The workspace has no value with the id \"$x\"")
        return workspace.catalog[rows[end]]
    end
end

"""
    computation(selection, index) -> Computation

The computation that gives one value of a selection, without loading its data.
"""
function computation(selection::Selection, index::Integer)::Computation
    data = selection.data::ItemData
    item = getfield(data, :items)[index]
    item isa Computation && return item
    ## The call that gives a value can give other values too: pick the value from its result.
    return Computation(pick, computation(getfield(data, :workspace), item), item)
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
    type, current = @lock catalog.lock (Catalogs.result_type(catalog, found), Catalogs.state(catalog, found) == Catalogs.CURRENT)
    place = store(workspace, type)
    (current && place !== nothing && haskey(place, type, found.index)) || return (cached=false, bytes=nothing)
    return (cached=true, bytes=DataBrowserAPI.stored_size(place, type, found.index))
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

# The name of the function of a computation: the start of its id, under which the cache keeps the
# key of its row. A package whose computations call values of its own type gives them a name.
# TODO: an anonymous function gets its generated name, such as `#3`, which changes from session to
# session; make its name from the content of its code (docs/plans/processing.md).
function_name(f) = string(nameof(f))

# The function, then the id of each argument, then the settings.
id(value::Computation) = string(function_name(value.f), "(",
    join(map(argument_id, value.args), ", "),
    isempty(value.settings) ? "" : "; " * join(("$name = $(repr(setting))" for (name, setting) in pairs(value.settings)), ", "),
    ")")
# TODO: the id of a computation repeats the ids of its inputs.
argument_id(x::Input) = id(x.catalog[x.row])
argument_id(x::Part) = x.id
argument_id(x::AbstractDataItem) = id(x)
argument_id(x::AbstractProject) = project_name(x)
argument_id(x::Union{AbstractDataSource,AbstractDataSourceItem}) = id(x)
# A computation in a selection is named by its own id: the item it gives may have the id of an item
# of the workspace, as a part of an item that a table passes on.
argument_id(selection::Selection) = "[" * join(map(selection.id, getfield(selection.data::ItemData, :items)) do name, x
    x isa Computation ? id(x) : name
end, ", ") * "]"
argument_id(xs::Union{AbstractVector,Tuple}) = "[" * join(map(argument_id, xs), ", ") * "]"
argument_id(x) = repr(x)
label(value::Computation) = function_name(value.f)

# ## Values

"""
    materialize_items(workspace, ids) -> Vector{AbstractDataItem}

The latest version of the values with the ids `ids`, in the same order.

A version that is not computed yet is computed now, ahead of background work, and
`materialize_items` waits for it. A failed value throws its error.

The data and the metadata of each delivered value belong together: when a value changes while it is
loaded, it is loaded again.
"""
function materialize_items(workspace::Workspace, ids::AbstractVector{<:AbstractString})::Vector{AbstractDataItem}
    catalog = workspace.catalog
    while true
        seen = wait_processed(workspace, ids)
        rows = @lock catalog.lock revision(workspace, ids) == seen ? Row[workspace.versions[x][end] for x in ids] : nothing
        rows === nothing && continue
        delivered = AbstractDataItem[pick(result, x) for (result, x) in zip(results(workspace, rows), ids)]
        revision(workspace, ids) == seen && return delivered
    end
end

# Ask for the latest version of each value ahead of background work. A request ends when its row has
# a result, so the callers ask again when the latest version moved to another row.
function Catalogs.request!(workspace::Workspace, ids::AbstractVector{<:AbstractString})::Nothing
    catalog = workspace.catalog
    @lock catalog.lock for x in ids
        rows = get(workspace.versions, x, nothing)
        rows === nothing || request!(catalog, rows[end], VIEWED_ITEM)
    end
    return nothing
end

"""
    processed(workspace, ids) -> Bool

Ask for the values `ids` ahead of background work, as `materialize_items` does, and tell whether the
latest version of each is computed now, or failed. The call does not wait, so a window can keep
showing what it showed until the values are ready.
"""
function processed(workspace::Workspace, ids::AbstractVector{<:AbstractString})::Bool
    catalog = workspace.catalog
    @lock catalog.lock begin
        request!(workspace, ids)
        return catalog.closed || all(ids) do x
            rows = get(workspace.versions, x, nothing)
            rows !== nothing && (Catalogs.state(catalog, rows[end]) in (Catalogs.CURRENT, Catalogs.FAILED) || Catalogs.stuck(catalog, rows[end]))
        end
    end
end

"""
    wait_processed(workspace, ids) -> UInt

Ask for the values `ids` ahead of background work, wait until the latest version of each is
computed, and return their [`revision`](@ref). A failed value throws its error.
"""
function wait_processed(workspace::Workspace, ids::AbstractVector{<:AbstractString})::UInt
    catalog = workspace.catalog
    @lock catalog.lock begin
        for x in ids
            ## When a row runs, the latest version of its value can move to another row.
            row = Catalogs.NOWHERE
            while true
                rows = get(workspace.versions, x, nothing)
                rows === nothing && error(catalog.closed ? "The workspace was closed" : "The workspace has no value with the id \"$x\"")
                rows[end] == row && break
                row = rows[end]
                state = wait(catalog, row, VIEWED_ITEM)
                state == Catalogs.CURRENT && continue
                catalog.closed && error("The workspace was closed")
                state == Catalogs.REMOVED && continue
                error(failure(workspace, row))
            end
        end
        return revision(workspace, ids)
    end
end

"""
    revision(workspace, ids) -> UInt

A number that changes when `materialize_items` would deliver other values for `ids`: a value has a
later version, or its latest version was computed again. A window keeps the number it drew with,
and draws again when it differs.
"""
function revision(workspace::Workspace, ids::AbstractVector{<:AbstractString})::UInt
    catalog = workspace.catalog
    @lock catalog.lock begin
        seed = UInt(0)
        for x in ids
            rows = get(workspace.versions, x, nothing)
            seed = rows === nothing ? hash(0, seed) : hash(rows[end].index, hash(Catalogs.state(catalog, rows[end]) == Catalogs.CURRENT,
                hash(Catalogs.revision(catalog, rows[end]), seed)))
        end
        return seed
    end
end

"""
    status_revision(workspace) -> Int

A number that rises whenever a computation of this or any other workspace changes its state, is
added or is removed. All workspaces of the Julia session share it, so it may also rise for a change
in another workspace. Values are added and removed only together with such a change. While the
number stays the same, so do the [`revision`](@ref) of any values and the latest version of each id.
Reading it costs the same for any number of items.
"""
status_revision(::Workspace)::Int = Catalogs.CHANGES[]

"""
    work_counts(workspace) -> (completed, total, running)

The jobs that ended, all jobs (ended, running and waiting), and the jobs that run now. The
performance window of the browser shows them.
"""
work_counts(workspace::Workspace)::Tuple{Int,Int,Int} = @lock workspace.catalog.lock (
    workspace.completed, workspace.completed + workspace.running + queued(workspace.catalog), workspace.running)
