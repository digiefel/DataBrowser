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
#     cache, a DuckDB file        a record of each row, by its key: the revision of its last result,
#                                 or its error; and for a row of the pipeline, the values it gives,
#                                 with their metadata and labels. The next session knows from it
#                                 which rows are current, and has their values without running them
#     stores, one for each        each result, by its revision; for a row of the pipeline, each
#       type of result            value it gives, by the revision of the value. A MemoryStore, the
#                                 default, loses the results when Julia exits; a DuckDBStore, as a
#                                 project made with DataBrowserRecipes uses, keeps them in a file
# ```
#
# The key of a row is its position in the catalog. The cache keeps the key of each computation by
# its id (see "Names and revisions"), so that the computation gets the same key in the next session.
#
# Each worker takes a job from the catalog and runs it:
#
# ```text
#     take! a job ─▶ compute the revision of its row ─▶ did the cache save this revision?
#                                                        │ no                    │ yes
#                                                        ▼                       ▼
#                                    call the function with the       finish!: the row is current,
#                                    results of its inputs            or failed with the saved
#                                      │                │             error. The function does not
#                                      │ returns a      │ throws, or  run: the value comes from its
#                                      │ result of the  │ returns     store when something needs it
#                                      │ right type     │ another type
#                                      ▼                ▼
#                          keep the result in     save the error
#                          the store of its type  in the cache
#                          and its revision in
#                          the cache. A result
#                          isequal to the last
#                          result of the row
#                          keeps the revision of
#                          the last result
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
# The revision of a row identifies its result (see "Names and revisions"). A current row whose store
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
# A `read` or a `process` must return a data item, or a vector of data items, each with an id that
# the row may give ([`Pipeline.jl`](Pipeline.md)); any other result fails the row. When a function
# throws, the row fails: the error is logged, the status panel of the browser shows the error next
# to its value, and the cache saves it. The `id`, `label`, `members` and `metadata` methods of the
# values count too, and so does a metadata value that the cache cannot hold, as one of another type
# than the earlier values of its name. When reading a source item fails, its values leave the
# workspace until a later read succeeds. A `process` that fails gives no values, and the value it
# was given keeps the failed row as its latest version, until the row runs again. A failed row does
# not run again, even in a later session, until its revision changes: its code, an input or an
# argument changed. To run failed rows again without a change, open the workspace with
# `rebuild=true`, which empties its cache.
#
# When the store refuses a result, as a `DuckDBStore` refuses metadata of another type than the
# values it holds under that name, the row fails in the same way, but the cache does not save the
# error: the next session runs the row again. The cache does not save the failure of a row that
# gives the id of an item of another row either. Also, a row whose saved values have such an id runs
# instead of taking them from the cache.
#
# TODO: a way to run one failed row again, as after a file was locked for a moment, or after the
# row that gave the same id is gone.

"""
    start_workers!(workspace)

Start the worker tasks of the workspace: one for each Julia thread, and at least two.
"""
function start_workers!(workspace::Workspace)::Nothing
    Threads.nthreads() == 1 && @warn("Julia runs with one thread: the browser waits while a computation runs. Start Julia with `--threads=auto,1`.", maxlog=1)
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
none, until the catalog closes. The worker counts the end of a job, even one that threw, in the
same take of the catalog lock as the next job, before it waits or returns. `work_counts` gives each
count at once.
"""
function work!(workspace::Workspace)::Nothing
    catalog = workspace.catalog
    job = nothing
    while true
        job = @lock catalog.lock begin
            ended = job !== nothing
            ended && (workspace.running -= 1; workspace.completed += 1; notify(catalog.changed))
            while true
                waiting = queued(catalog)
                job = take!(catalog)
                job === nothing || catalog.closed || (workspace.running += 1)
                ## The counts and `keep!` follow the end of a job, the start of one, and the queued
                ## rows that `take!` drops because they can no longer start, which may be the last
                ## work of the workspace.
                if ended || job !== nothing || queued(catalog) < waiting
                    @atomic workspace.work = (workspace.completed, workspace.completed + workspace.running + queued(catalog), workspace.running)
                    changed!(workspace)
                end
                (job !== nothing || catalog.closed) && break
                ended = false
                wait(catalog.changed)
            end
            catalog.closed ? nothing : job
        end
        job === nothing && return nothing
        try
            ## The latest world, so that a job runs the code defined after the worker started.
            Base.invokelatest(run!, workspace, job)
        catch error
            @error "A job of the workspace failed" exception=(error, catch_backtrace())
        end
    end
end

"""
    run!(workspace, job)

Compute the row of `job`, keep its result, and add the rows that its values need. A row whose
current revision is the one the cache saved becomes current, or failed, without running, with the
revision of its saved result. When only the code that describes its values changed (see
[`revision`](@ref)), the row takes its values from their stores, and computes their ids, labels,
members and metadata again; it runs when a store no longer has one of them. A result `isequal` to
the last result of the row keeps the revision of the last result, so that the rows that read it
find the revisions they last ran with. A result of the wrong type fails the row: a `read` or a
`process` must return an `AbstractDataItem`, or a vector of them. So does a result with an id that
the row may not give (see [`given!`](@ref)), or with a metadata value that the cache cannot hold.
"""
function run!(workspace::Workspace, job::Job)::Nothing
    catalog, row = workspace.catalog, job.row
    ## Until `finish!` ends the job, every error fails the row, so that no row stays running without
    ## a job. The cache saves only the errors of the project's code, under the revision of the row:
    ## after any other error, the next session runs the row again.
    value, stage, at, record, current, previous = try
        @timed_dbg "job.revision" @lock catalog.lock @timed_dbg "job.revision.held" begin
            at = revision(workspace, row)
            record = get(workspace.cache.db, row.index, nothing)
            previous = (revision=Catalogs.revision(catalog, row), type=Catalogs.result_type(catalog, row))
            if record !== nothing && record.revision != at
                ## A row that runs no longer gives the result that the cache saved in an earlier
                ## session: the result or its values leave the stores.
                # TODO: a row outside the pipeline that failed keeps its last result in its store, and
                # the cache saves the failure without the revision of that result: when the session
                # ends before the row has a result again, the store keeps that result for good.
                if previous.revision == 0 && isempty(record.failure)
                    workspace.items.rows.stage[row] === nothing && forget!(workspace, record.type, record.result_revision)
                    foreach(x -> forget!(workspace, x.type, value_revision(x.id, record.result_revision)), record.items)
                end
                record = nothing
            end
            catalog[row], workspace.items.rows.stage[row], at, record, record !== nothing && described(workspace, row, record), previous
        end
    catch error
        return failed!(workspace, job, nothing, error, catch_backtrace())
    end
    pipeline = stage !== nothing
    if current
        @timed_dbg "job.restore" @lock catalog.lock begin
            finish!(catalog, job; failed=!isempty(record.failure), revision=record.result_revision, type=record.type) &&
                restored!(workspace, row, record)
            publish!(workspace)
        end
        return nothing
    end
    ## When only the code that describes the values changed, the row takes them from their stores.
    found = record === nothing || !isempty(record.failure) ? [nothing] :
        only(kept(workspace, [Tuple{Type,UInt64}[(x.type, value_revision(x.id, record.result_revision)) for x in record.items]]))
    reuse = !isempty(found) && all(!isnothing, found)
    output = try
        reuse ? (record.type <: AbstractVector ? convert(record.type, something.(found)) : something(only(found))) :
            @timed_dbg "job.call" call(workspace, row, value)
    catch error
        return failed!(workspace, job, at, error, catch_backtrace())
    end
    given = output isa AbstractVector ? output : [output]
    pipeline && !all(x -> x isa AbstractDataItem, given) && return failed!(workspace, job, at,
        ErrorException("$(function_name(value.f)) returned a $(typeof(output)), not an item or a vector of items"), backtrace())
    ## The ids, labels, members and metadata of the values are the project's code too: when it
    ## throws, the cache saves the failure with the types of the values, whose code describes them.
    items = SavedOutput[]
    try
        pipeline && append!(items, (; id=id(x), stage=Int8(stage), label=label(workspace.project, x), type=typeof(x),
            members=x isa AbstractGroup ? members(x) : nothing, metadata=metadata_dict(metadata(x))) for x in given)
        allunique(x.id for x in items) ||
            error("it gives the id \"$(first(x.id for x in items if count(y -> y.id == x.id, items) > 1))\" twice")
    catch error
        return failed!(workspace, job, at, error, catch_backtrace(), unique(typeof.(given)))
    end
    ## A result `isequal` to the last result of the row, which its store still has, is the same
    ## result: the row keeps the revision of the last result. The readers of a row of the pipeline
    ## find its values by id, so the ids count too. `isequal` is the project's code: when it throws,
    ## the results differ.
    # TODO: compare each value of a row of the pipeline on its own. A `Part` follows the revision of
    # the whole row, so one changed value of a read runs the `process` of every value again.
    # TODO: when the values from the stores get other ids, those under the old ids stay in the stores.
    ids = [x.id for x in items]
    same = reuse ? isequal(ids, [x.id for x in record.items]) :
        previous.revision != 0 && typeof(output) === previous.type && @timed_dbg "job.compare" try
            found = only(kept(workspace, [row]))
            before = found === nothing ? nothing : output isa AbstractVector ? something(found) : [something(found)]
            before !== nothing && Base.invokelatest(isequal, before, given) && (!pipeline || isequal(id.(before), ids))
        catch
            false
        end
    ## The same result keeps its revision, under which its store has it already.
    result = !same ? at : reuse ? record.result_revision : previous.revision
    written = !same && keepable(catalog, job)
    try
        @timed_dbg "job.keep" written && keep!(workspace, value, output, result; pipeline)
    catch error
        return failed!(workspace, job, nothing, error, catch_backtrace())
    end
    outputs = Output[Output(x.id, x.type, x.label, x.members, output_key!(workspace.cache.db, row.index, x.id),
        value_revision(x.id, result)) for x in items]
    saved = false
    @timed_dbg "job.finish" @lock catalog.lock @timed_dbg "job.finish.held" try
        ## A result that the row does not keep leaves the store.
        finish!(catalog, job; revision=result, type=typeof(output)) ||
            return written ? keep!(workspace, value, output, result; pipeline, forget=true) : nothing
        ## The last result of the row leaves its store; for a row of the pipeline, `given!` does the
        ## same with each value.
        pipeline || previous.revision in (0, result) || forget!(workspace, previous.type, previous.revision)
        haskey(workspace.errors, row) && (workspace.errors = Base.delete(workspace.errors, row))
        ## The cache saves the record of the row whole, or throws and changes nothing when it cannot
        ## hold one of the metadata values. The table `items` then takes the same metadata.
        @timed_dbg "job.finish.record" workspace.cache.db[row.index] = (; call=id(value), revision=at, result_revision=result,
            item_revision=revision(workspace, row, [x.type for x in items]), type=typeof(output), failure="", items)
        saved = true
        if pipeline
            @timed_dbg "job.finish.finished!" finished!(workspace, row, outputs)
            foreach((output, x) -> store!(workspace.items, output, x.metadata), outputs, items)
        end
        @timed_dbg "job.finish.publish!" publish!(workspace)
    catch error
        ## When the cache cannot hold a metadata value, the row fails, and the cache saves the
        ## failure. When another row gives one of its ids, `finished!` throws, the row fails, and the
        ## next session runs the row again.
        written && keep!(workspace, value, output, result; pipeline, forget=true)
        failed!(workspace, job, saved ? nothing : at, error, catch_backtrace(), unique(typeof.(given)))
    end
    return nothing
end

"""
    failed!(workspace, job, revision, error, backtrace, types=())

Fail the row of `job` and save its message in the cache under `revision`, so that the next session
shows the same failure without running the row. `types` are the types of the values that the row
gave when describing them failed: the cache saves the failure until their `label`, `id`, `members`
or `metadata` methods change too. A `revision` of `nothing` removes the record of the row from the
cache instead, so that the next session runs the row. The message goes to `report_error`, and the
status panel of the browser shows the message next to the value. A row of the pipeline that fails
gives no values.
"""
function failed!(workspace::Workspace, job::Job, at::Union{Nothing,UInt64}, error, backtrace, types=())::Nothing
    catalog, row = workspace.catalog, job.row
    context = @lock catalog.lock begin
        stage, f = workspace.items.rows.stage[row], catalog[row].f
        about = stage == SOURCE_READ ? "Source item: $(subject(workspace, row))" :
            stage !== nothing ? "Function: $(function_name(f))\n  Item: $(subject(workspace, row))" :
            "Computation: $(subject(workspace, row))"
        "A computation failed\n  $about\n  Source: $(DataBrowserAPI.source_description(workspace.source))"
    end
    message = DataBrowserAPI.error_summary(error, backtrace) * "\n\n" * context
    @lock catalog.lock begin
        finish!(catalog, job; failed=true) || return nothing
        workspace.errors = Base.PersistentDict(workspace.errors, row => subject(workspace, row) => "$(function_name(catalog[row].f)) failed: " * message)
        # TODO: a record removed here may leave its values in the stores.
        at === nothing ? delete!(workspace.cache.db, row.index) : (workspace.cache.db[row.index] = (; call=id(catalog[row]),
            revision=at, result_revision=UInt64(0), item_revision=revision(workspace, row, types), type=Tuple{types...},
            failure=message, items=SavedOutput[]))
        workspace.items.rows.stage[row] === nothing || finished!(workspace, row, nothing)
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
    return last(get(workspace.errors, row, "" => "The computation failed"))
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
        @lock workspace.catalog.lock row in workspace.catalog && write!(workspace.items, workspace.items.rows.execution, row.index, execution)
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

# ## Names and revisions
#
# The computation of each row has an id, which is its function with the id of each argument, as
# `fit(a/1)`. Before a row runs, the workspace computes its revision, a hash of the name of its
# function, the code revision of the function, the revisions of the results of its inputs, and its
# other arguments and settings: the same revision means the same result, even in another session. A
# source item contributes its id and its fingerprint, such as the modification time of a file; a
# source item without a fingerprint gives a new revision each time, so that it is always read again.
#
# The result of the row gets this revision, unless the row had a result before and the new result is
# `isequal` to it: then the row keeps the revision of its last result. For a row of the pipeline,
# the ids of its values must be equal too. The readers of the row then compute the revisions they
# last ran with, and become current without calling their functions: when an edit of a `process`
# method changes nothing in what it returns, the rows that read its values do not call their
# functions again. Each value that a row of the pipeline gives has a revision of its own, a hash of
# its id and the revision of the result of the row, which the `process` of the value uses as the
# revision of its input.
#
# The cache saves a *record* of each row under its key: the id of its computation, the revision
# that it computed before it ran, the revision of its result, its error when it failed, and the
# values it gives, with their labels and metadata. The record also holds the *item revision* of the
# row, the code revision of the `label`, `id`, `members` and `metadata` methods of the types of its
# values. The next session gives the key to the first row whose computation has that id.
#
# The *code revision* of a function, which the revision of a row uses, is a hash of the code that
# the function can reach; the workspace keeps it in memory (see "Code changes"). The catalog also
# counts the *changes* of each row: the number rises when the code, an input or the computation of
# the row changes, so that the workspace drops the result of a job that started before (see
# [`Catalogs.jl`](../Catalogs.md)).
#
# `revision(workspace, computation)` and `revision(workspace, items)` are numbers that a window
# compares to know when to draw again; they follow the changes of the rows. `cache[key] = record`
# saves the record of a row whole, and `get(cache, key, nothing)` reads it.
#
# When a workspace opens again, a row whose saved revision and item revision are those it computes
# now is current, with the revision of its saved result, or failed with its saved error, without
# running. Its metadata is the metadata that the cache saved, and its value comes from its store;
# when the store no longer has it, as a `MemoryStore` after a restart, the row runs again when
# something needs its value. When only the item revision differs, as after an edit of a `label`
# method, the row takes its values from their stores and computes their labels, ids, members and
# metadata again, without calling its function (see [`run!`](@ref)).

"""
    revision(workspace, row) -> UInt64

The revision of `row`, which it computes before it runs: the same revision means the same result,
even in another session. It follows the code of its function, the revisions of the results of its
inputs, and its other arguments and settings. Its result gets this revision, or keeps the revision
of the last result when the two are `isequal` (see [`run!`](@ref)). The caller holds the catalog
lock.
"""
function revision(workspace::Workspace, row::Row)::UInt64
    value = workspace.catalog[row]
    signature = Tuple{typeof(value.f),map(x -> argument_type(workspace, x), value.args)...}
    get!(() -> Type[signature], workspace.signatures, row)[1] = signature
    ## Types and symbols hash differently in another session; their names do not.
    seed = hash(function_name(value.f), hash(code!(workspace, signature, value.f).revision.hash))
    for x in value.args
        seed = hash(argument_revision(workspace, row, x), seed)
    end
    return hash(repr(value.settings), seed)
end

"""
    revision(workspace, row, types) -> UInt64

The item revision of `row`: the code revision of the `label`, `id`, `members` and `metadata`
methods of `types`, the types of the values that the row gives. When it changes, the row computes
the labels, ids, members and metadata of its values again (see [`run!`](@ref)). The caller holds
the catalog lock, and computed `revision(workspace, row)` before.
"""
function revision(workspace::Workspace, row::Row, types)::UInt64
    signatures = Type[Tuple{typeof(label),typeof(workspace.project),T} for T in unique(types)]
    workspace.signatures[row] = Type[first(workspace.signatures[row]); signatures]
    return foldl((seed, signature) -> hash(code!(workspace, signature, label).revision.hash, seed), signatures; init=UInt64(0))
end

"""
    value_revision(id, revision) -> UInt64

The revision of the value `id` that a row of the pipeline gives, when `revision` is the revision of
the result of the row: the rows that read the value, and the store of its type, use it.
"""
value_revision(x::AbstractString, at::UInt64)::UInt64 = hash(x, at)

argument_type(workspace::Workspace, x::Input) = Catalogs.result_type(workspace.catalog, x.row)
function argument_type(workspace::Workspace, x::Part)
    found = output(workspace, x.of.row, x.id)
    return found === nothing ? Any : found.type
end
argument_type(::Workspace, ::MemberValues{T}) where {T} = Vector{T}
argument_type(::Workspace, x) = typeof(x)

# The values of members count as the sum of a hash of the id and the revision of each, which the
# workspace keeps as they change (see `input!`).
argument_revision(workspace::Workspace, row::Row, ::MemberValues)::UInt64 = workspace.taken[row].revision
argument_revision(workspace::Workspace, ::Row, x)::UInt64 = argument_revision(workspace, x)
argument_revision(workspace::Workspace, x::Input)::UInt64 = Catalogs.revision(workspace.catalog, x.row)
argument_revision(workspace::Workspace, x::Part)::UInt64 = value_revision(x.id, argument_revision(workspace, x.of))
argument_revision(workspace::Workspace, x::Union{Tuple,AbstractVector{<:Union{Input,Part}}})::UInt64 =
    foldl((seed, v) -> hash(argument_revision(workspace, v), seed), x; init=UInt64(0))
argument_revision(workspace::Workspace, x::Selection)::UInt64 =
    foldl((seed, row) -> hash(Catalogs.revision(workspace.catalog, row), seed), Catalogs.input_rows(x); init=hash(argument_id(x)))
# A source item without a fingerprint may have changed at any time: its result is never the saved
# one.
argument_revision(::Workspace, x::AbstractDataSourceItem)::UInt64 =
    fingerprint(x) === nothing ? rand(UInt64) : hash(id(x), hash(repr(fingerprint(x))))
argument_revision(::Workspace, x)::UInt64 = hash(argument_id(x))

"""
    code!(workspace, signature, f) -> Code

The code that the rows of `signature` run, followed from the roots that [`code_roots`](@ref) gives,
with its code revision. It is computed once for each signature, and again after a code change. The
caller holds the catalog lock.
"""
function code!(workspace::Workspace, signature::Type, f)::Code
    return get!(workspace.code, signature) do
        roots = code_roots(workspace.project, signature, f)
        code = Code(f, roots, Base.get_world_counter(), code_revision(roots))
        warn_untracked(signature, code)
        code
    end
end

"""
    code_roots(project, signature, f) -> Vector

The functions, methods and types whose code runs when a function is called with the argument
types of `signature`. For a stage of the pipeline, these are the type it runs for and the methods
of the stage that can apply to it. For the signature `Tuple{typeof(label),P,T}`, which describes
the values of type `T` (see [`revision`](@ref)), these are `T` and its `label`, `id`, `members` and
`metadata` methods. Else the root is the function. A callable object that is not a function, such
as a fit, runs the methods that make its type callable, whose parameters include the types of the
functions it holds. A type, such as `SourceGroup`, runs its constructors.
"""
function code_roots(project::AbstractProject, signature::Type, f)::Vector
    found = stage(signature)
    found === nothing && return f isa Function ? Any[f] : Any[f isa Type ? f : typeof(f); collect(methods(f))]
    at, T = found
    signatures = DataBrowserAPI.stage_signatures(typeof(project), at, T)
    return Any[T; [method for (g, types) in signatures for method in methods(g, types)]]
end
function code_roots(project::AbstractProject, ::Type{<:Tuple{typeof(label),Any,T}}, f)::Vector where {T}
    signatures = [(label, Tuple{typeof(project),T}), (label, Tuple{T}), (id, Tuple{T}), (members, Tuple{T}), (metadata, Tuple{T})]
    return Any[T; [method for (g, types) in signatures for method in methods(g, types)]]
end

stage(::Type{<:Tuple{typeof(read),Any,Any,S}}) where {S} = (SOURCE_READ, S)
stage(::Type{<:Tuple{typeof(process),Any,I}}) where {I} = (ITEM_PROCESS, I)
stage(::Type{<:Tuple{typeof(process),Any,G,AbstractVector}}) where {G} = (GROUP_PROCESS, G)
stage(::Type{<:Tuple{typeof(process),Any,M,G}}) where {M,G} = (MEMBER_PROCESS, G)
stage(_) = nothing

"""
    restore!(workspace, row) -> Bool

Give `row` the result that the cache saved for it, with the revision of that result, when the
revision and the item revision of the row are those of its record, and its inputs are current,
without a job. Return whether it did. When another row gives one of the saved values, the cache
forgets the record, and the row is stale and runs again. The caller holds the catalog lock.
"""
function restore!(workspace::Workspace, row::Row)::Bool
    catalog = workspace.catalog
    Catalogs.state(catalog, row) in (Catalogs.MISSING, Catalogs.STALE) || return false
    all(input -> Catalogs.state(catalog, input) == Catalogs.CURRENT, Catalogs.inputs(catalog, row)) || return false
    ## The revision of the row is computed only when the cache saved a record for the row.
    record = get(workspace.cache.db, row.index, nothing)
    record === nothing && return false
    @timed_dbg("restore.revision", record.revision == revision(workspace, row) && described(workspace, row, record)) || return false
    Catalogs.restore!(catalog, row; failed=!isempty(record.failure), revision=record.result_revision, type=record.type) || return false
    return @timed_dbg "restore.restored!" restored!(workspace, row, record)
end

# Whether the code that describes the values of `record`, the record of `row`, is the code that
# describes them now. A row that failed while describing its values saved their types as the type
# of its result, a `Tuple`.
described(workspace::Workspace, row::Row, record)::Bool = record.item_revision ==
    revision(workspace, row, isempty(record.failure) ? [x.type for x in record.items] : fieldtypes(record.type))

# The values and the metadata of a row, or its error, as its record holds them. Gives `false` when
# another row gives one of these values: the row is stale then, and runs again.
function restored!(workspace::Workspace, row::Row, record)::Bool
    failed = !isempty(record.failure)
    failed && (workspace.errors = Base.PersistentDict(workspace.errors,
        row => subject(workspace, row) => "$(function_name(workspace.catalog[row].f)) failed: " * record.failure))
    workspace.items.rows.stage[row] === nothing && return true
    outputs = @timed_dbg "restored.outputs" Output[Output(x.id, x.type, x.label, x.members,
        output_key!(workspace.cache.db, row.index, x.id), value_revision(x.id, record.result_revision)) for x in record.items]
    try
        @timed_dbg "restored.finished!" finished!(workspace, row, failed ? nothing : outputs)
    catch
        ## The row runs, so that it fails again, or gives its values when the other row is gone.
        # TODO: when the saved result has an older revision than the row, its values stay in the
        # stores.
        delete!(workspace.cache.db, row.index)
        Catalogs.invalidate!(workspace.catalog, row)
        return false
    end
    foreach((output, x) -> store!(workspace.items, output, x.metadata), outputs, record.items)
    return true
end

# ## Results
#
# A store keeps each result under its revision, so that a row that is current does not run again
# for each task that needs its value. Each value that a row of the pipeline gives goes to the store
# of its own type, under the revision of the value. The same revision means the same result, in any
# workspace and session: workspaces can share a store, and a store can keep its results from one
# session to the next. When a row gets a result with another revision, its last result leaves the
# store. `storage(project, T)` chooses the store for results of type `T`: items, or any other Julia
# value. By default, each result type has its own `MemoryStore` of 64 MiB, which removes the least
# recently used results first, and loses them when Julia exits.
# A project made with DataBrowserRecipes keeps the results of every type in one `DuckDBStore`, the
# file `values.duckdb` in the folder of its Julia environment, which all such projects of that
# environment share, so the results stay from one session to the next. A project can choose another
# size, or another store:
#
# ```julia
# DataBrowserAPI.storage(::MyProject, ::Type{MyItem}) = MemoryStore(; max_bytes=512 * 1024^2)
# DataBrowserAPI.storage(::MyProject, ::Type{MyFit}) = DuckDBStore(joinpath(@__DIR__, "results.duckdb"))
# ```
#
# A store of `nothing` keeps no results of that type: the row runs again when something needs its
# value. When `storage` throws, as when another Julia process has the file of a `DuckDBStore` open,
# the workspace warns and keeps the results of that type in a `MemoryStore`. A result that its
# store cannot read counts as lost: the row runs again. A store receives a copy of each result and
# gives copies; the docstring of `AbstractStore` gives its methods. Three kinds of results never go
# to a store:
#
# - `nothing`;
# - a `Selection`, which reads the workspace each time something takes an item from it;
# - the result of `view(item, selection)`, the part of an item that a window chose.

"""
    store(workspace, type) -> Union{Nothing,AbstractStore}

The store that the project chooses for results of `type`, asked once for each type. It is `nothing`
for the types of results that never go to a store, `Nothing` and `Selection`, and when `storage`
gives `nothing`. When `storage` throws, it is a `MemoryStore`, with a warning. [`keep!`](@ref) also
skips the result of `view`.

A store file written by an older version of DataBrowser is handled as an old cache file: while the
cache rebuilds, its file is deleted and the store starts over; otherwise, the results stay in
memory, and the workspace keeps the error, so that the browser offers a rebuild.
"""
function store(workspace::Workspace, type::Type)::Union{Nothing,AbstractStore}
    type <: Union{Nothing,Selection} && return nothing
    return @lock workspace.stores_lock get!(workspace.stores, type) do
        try
            try
                Base.invokelatest(DataBrowserAPI.storage, workspace.project, type)
            catch error
                error isa ProjectCacheSchemaError && workspace.cache.operation === :rebuild || rethrow()
                DataBrowserCache._remove_cache_files!(error.path)
                Base.invokelatest(DataBrowserAPI.storage, workspace.project, type)
            end
        catch error
            if error isa ProjectCacheSchemaError
                @atomicreplace workspace.cache.disk_error nothing => error
                @warn("A store file is out of date: its results are kept in memory until the cache rebuilds",
                    store=error.path, maxlog=1)
            else
                @warn("The store of a result type cannot be used: its results are kept in memory", type,
                    exception=(error, catch_backtrace()), maxlog=1)
            end
            DataBrowserCache.MemoryStore()
        end
    end
end

"""
    keep!(workspace, computation, result, revision; pipeline, forget=false)

Save a copy of `result`, the result of `computation`, in the store of its type, under `revision`,
the revision of the result. With `pipeline=true`, for a row of the pipeline, save each value of the
result in the store of the type of the value, under the revision of the value (see
[`value_revision`](@ref)). The result of `view(item, selection)`, and one value picked from the
result of another row, is not saved: it is made again when needed, and another copy of the item
would push other results out. With `forget=true`, delete from the stores what `keep!` saves for
`result`.
"""
function keep!(workspace::Workspace, value::Computation, output, at::UInt64; pipeline::Bool, forget::Bool=false)::Nothing
    value.f in (view, pick) && return nothing
    for (key, x) in (pipeline ? [(value_revision(id(x), at), x) for x in (output isa AbstractVector ? output : [output])] : [(at, output)])
        place = store(workspace, typeof(x))
        ## `deepcopy` is a dynamic call: a method of a package loaded later then does not invalidate this code.
        place === nothing || (forget ? delete!(place, typeof(x), key) : write(place, key, Base.invokelatest(deepcopy, x)))
    end
    return nothing
end

# Delete the result of type `type` and revision `at` from its store.
function forget!(workspace::Workspace, type::Type, at::UInt64)::Nothing
    place = store(workspace, type)
    place === nothing || delete!(place, type, at)
    return nothing
end

# The type and the revision under which the stores keep the result of a row, or for a row of the
# pipeline, each value that it gives, from its stage, the values that it gave, and `stored`, the type
# and the revision of its result.
store_keys(stage, outputs, stored::Tuple{Type,UInt64})::Vector{Tuple{Type,UInt64}} = stage !== nothing ?
    Tuple{Type,UInt64}[(output.type, output.revision) for output in something(outputs, Output[])] : [stored]

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
must be computed again. The result of a row of the pipeline is read from the stores of its values,
and must be computed again when one of them is missing, or when the row has no values, as after it
failed. The results of `view` and `pick`, which `keep!` does not save, are always computed again.
"""
function kept(workspace::Workspace, rows::Vector{Row})::Vector{Union{Nothing,Some}}
    catalog = workspace.catalog
    return kept(workspace, @lock catalog.lock [(catalog[row].f, workspace.items.rows.stage[row], workspace.items.rows.outputs[row],
        (Catalogs.result_type(catalog, row), Catalogs.revision(catalog, row))) for row in rows])
end
# The results of `rows`, which `version` shows current, from the cells of `version`: without the
# catalog lock.
kept(workspace::Workspace, version::Version, rows::Vector{Row})::Vector{Union{Nothing,Some}} = kept(workspace,
    [(something(version.rows.computation[row]).f, version.rows.stage[row], version.rows.outputs[row], something(version.rows.stored[row]))
        for row in rows])
# The results of rows, each given as its function, its stage, the values that it gave, and the type
# and the revision of its result.
function kept(workspace::Workspace, facts::Vector)::Vector{Union{Nothing,Some}}
    vectors = [stage !== nothing && first(stored) <: AbstractVector for (_, stage, _, stored) in facts]
    found = kept(workspace, Vector{Tuple{Type,UInt64}}[store_keys(stage, outputs, stored) for (_, stage, outputs, stored) in facts])
    ## Any other result has one part, or none when a row of the pipeline failed.
    return Union{Nothing,Some}[f in (view, pick) || vector && outputs === nothing || any(isnothing, values) ? nothing :
        vector ? Some(identity.(something.(values))) : get(values, 1, nothing) for ((f, _, outputs, _), values, vector) in zip(facts, found, vectors)]
end

"""
    kept(workspace, parts) -> Vector{Vector{Union{Nothing,Some}}}

The values kept by the stores under each type and revision of `parts`, as `Some(value)`, and
`nothing` for each value missing from its store. The values of one type are read together, outside
any lock.
"""
function kept(workspace::Workspace, parts::Vector{Vector{Tuple{Type,UInt64}}})::Vector{Vector{Union{Nothing,Some}}}
    found = [Vector{Union{Nothing,Some}}(nothing, length(part)) for part in parts]
    by_type = Dict{Type,Vector{Tuple{Int,Int}}}()
    for (position, part) in enumerate(parts), (index, (type, _)) in enumerate(part)
        type === Nothing ? (found[position][index] = Some(nothing)) : push!(get!(Vector{Tuple{Int,Int}}, by_type, type), (position, index))
    end
    for (type, places) in by_type
        place = store(workspace, type)
        place === nothing && continue
        read_values = try
            read(place, type, [parts[position][index][2] for (position, index) in places])
        catch error
            @warn("A store could not read results: they are computed again", type, exception=(error, catch_backtrace()), maxlog=1)
            continue
        end
        for ((position, index), value) in zip(places, read_values)
            value === nothing || (found[position][index] = Some(value))
        end
    end
    return found
end

"""
    computed!(workspace, row)

Compute the result of a current row again, once for all the tasks that ask for it at the same
time, and keep it. The row stays current: it ran before with the same revision, and its store had
dropped the result.
"""
function computed!(workspace::Workspace, row::Row)
    ## TODO: this reads the catalog under its lock, so a client that asks for a result that its
    ## store lacks waits for the lock.
    catalog = workspace.catalog
    one = @lock catalog.lock get!(ReentrantLock, workspace.row_locks, row)
    @lock one begin
        found = only(kept(workspace, [row]))
        found === nothing || return something(found)
        value, pipeline, before, at = @lock catalog.lock (catalog[row], workspace.items.rows.stage[row] !== nothing,
            Catalogs.changes(catalog, row), Catalogs.revision(catalog, row))
        output = call(workspace, row, value)
        @lock catalog.lock Catalogs.changes(catalog, row) == before || return output
        keep!(workspace, value, output, at; pipeline)
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
        write!(workspace.items, workspace.items.rows.execution, row.index, nothing)
        haskey(workspace.errors, row) && (workspace.errors = Base.delete(workspace.errors, row))
        Catalogs.state(catalog, row) == Catalogs.REMOVED || continue
        forget!(workspace, Catalogs.result_type(catalog, row), Catalogs.revision(catalog, row))
        delete!(workspace.cache.db, row.index)
        foreach(found -> delete!(found, row), (workspace.signatures, workspace.row_locks, workspace.evaluated))
        ## The cells of a removed row go back to the defaults, those of `NOWHERE`.
        foreach(column -> write!(workspace.items, column, row.index, column[Catalogs.NOWHERE]), workspace.items.rows)
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
# The roots of a row of the pipeline are the type it runs for and the methods of the stage that can
# apply to it. A Recipes project defines these methods from its registrations, with the callbacks in
# them, so a changed callback is changed code too. The values that the row gives add a signature for
# each of their types, whose roots are the type and its `label`, `id`, `members` and `metadata`
# methods: when only these change, the row computes the labels, ids, members and metadata of its
# values again, from the values in the stores. The roots of any other row are its function. A callable
# object that is not a function, such as a fit, has as roots its type and the methods that make the
# type callable: the parameters of the type include the types of the functions it holds, such as the
# curve of the fit. The workspace follows the code only into `Main` and into packages developed from
# a local folder (`Pkg.develop`); for every other package, the Julia version and the Manifest count
# instead.
#
# The revision of each row includes the code revision of its signature. Twice a second, the
# workspace asks Revise to load saved edits, including files tracked with `includet`, even when the
# REPL is idle. After a method definition, or when the roots differ, the workspace computes the code
# revision again; `evaluate` does the same check first when a method was defined since the last
# check. When the code revision changed, the rows of that signature become stale, and with them
# every row that reads them: source items are read again, as if the source had changed them, and
# items are processed again when a window shows them or a script reads them, or in the background
# with `background_processing=true`. The same code defined again, as when a script runs again,
# changes nothing.
#
# While a browser is open, the keyboard focus of its main window controls these checks: an inactive
# window pauses them, and gaining focus resumes them. Without a browser, including after closing
# one, the workspace keeps checking.
#
# The code revision does not see a mutable value changed in place, nor a change to a macro: the
# functions that use a macro keep their old expansion until they are defined again. The workspace
# warns about code that it cannot follow: a non-constant global, a call through `eval`,
# `invokelatest` or a computed name, a generated function, and a value it cannot read. The warning
# shows the way from the root to it.

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
        ## Every value and group is checked again when a method applies now that did not, or the
        ## other way around.
        if !isequal(answers, asked)
            workspace.methods = answers
            refresh!(workspace, collect(keys(workspace.versions)))
        end
        changed = Set{Type}(signature for (signature, code) in current
            if code.revision.hash != workspace.code[signature].revision.hash)
        for signature in changed
            before, after = workspace.code[signature].revision.parts, current[signature].revision.parts
            @info("The code of a computation changed: its results are computed again",
                signature, changes=sort!(unique!(first.(symdiff(before, after)))))
        end
        merge!(workspace.code, current)
        for (row, signatures) in workspace.signatures
            any(in(changed), signatures) && Catalogs.invalidate!(catalog, row)
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
its latest version, so that it follows the changes of that value. `latest(id)` gives the row of the
latest version of a value, or `Catalogs.NOWHERE`; by default, it reads the versions in the catalog,
and the caller holds the catalog lock.
"""
bound(workspace::Workspace, value::Computation, latest=x -> last(get(workspace.versions, x, [Catalogs.NOWHERE]))) =
    Computation(value.f, map(x -> bound_argument(workspace, x, latest), value.args), value.settings)
bound_argument(workspace::Workspace, x::Computation, latest) = bound(workspace, x, latest)
function bound_argument(workspace::Workspace, x::AbstractDataItem, latest)
    row = latest(id(x))
    return row == Catalogs.NOWHERE ? x : Part(Input(workspace.catalog, row), id(x))
end
bound_argument(workspace::Workspace, x::Tuple, latest) = map(v -> bound_argument(workspace, v, latest), x)
bound_argument(workspace::Workspace, x::AbstractVector, latest) =
    any(v -> v isa AbstractDataItem, x) ? map(v -> bound_argument(workspace, v, latest), x) : x
bound_argument(::Workspace, x::Selection, _) = x
bound_argument(::Workspace, x, _) = x

# A selection reads the latest version of each of its values, and the result of each of its
# computations.
function Catalogs.input_rows(selection::Selection)::Vector{Row}
    data = selection.data::ItemData
    workspace = getfield(data, :workspace)
    found = Row[]
    for x in getfield(data, :items)
        row = x isa String ? last(get(workspace.versions, x, [Catalogs.NOWHERE])) :
            something(findfirst(isequal(bound(workspace, x)), workspace.catalog), Catalogs.NOWHERE)
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
A failed computation, or one whose input failed, throws its error. Once `evaluate` returns or
throws, `last_execution`, `cache_info` and `revision` show the computation as it ended.
"""
function evaluate(workspace::Workspace, value::Computation)
    items = workspace.items
    ## The task `keep!` adds the computation to the catalog and requests its row, and puts the row
    ## in `added` once a version shows it. The call then waits, without the catalog lock, for a
    ## version where the row is current or failed, so that many calls wait at the same time.
    added = Ref{Any}(value)
    version = @lock items.lock try
        push!(items.readers, added)
        notify(items.event)
        while true
            items.closed && error("The workspace was closed")
            added[] isa Exception && throw(added[])
            version = @atomic items.version
            added[] isa Row && version.rows.readiness[added[]] in (CURRENT, FAILED) && break
            wait(items.published)
        end
        version
    finally
        deleteat!(items.readers, findfirst(reader -> reader === added, items.readers))
    end
    row = added[]
    version.rows.readiness[row] == FAILED && error(version.rows.failure[row])
    ## The result from its store, as the version shows it, or else computed again.
    found = only(kept(workspace, version, [row]))
    return found === nothing ? computed!(workspace, row) : something(found)
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
    version = @atomic workspace.items.version
    row = cell(version, x, :version, Catalogs.NOWHERE)
    row == Catalogs.NOWHERE && error("The workspace has no value with the id \"$x\"")
    return version.rows.computation[row]
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

# The row of a computation, with the latest versions of the values in `version`, or
# `Catalogs.NOWHERE` when the workspace does not have it, in the catalog of `version`. The catalog
# stays as it is, and no lock is taken.
row(workspace::Workspace, version::Version, value::Computation)::Row =
    something(findfirst(isequal(bound(workspace, value, x -> cell(version, x, :version, Catalogs.NOWHERE))),
        version.catalog), Catalogs.NOWHERE)

# The time of an execution covers the call of the function, with compilation and waits, and not the
# evaluation of its inputs or the storage of its result.
# The method of `DataBrowserAPI.last_execution` for a workspace.
function last_execution(workspace::Workspace, value::Computation)::Union{Nothing,ComputationExecution}
    version = @atomic workspace.items.version
    found = row(workspace, version, value)
    return version.rows.readiness[found] in (CURRENT, FAILED) ? version.rows.execution[found] : nothing
end

# The method of `DataBrowserAPI.cache_info` for a workspace: whether the stores have the result of a
# current computation, or each value of a row of the pipeline, and its size.
function cache_info(workspace::Workspace, value::Computation)
    version = @atomic workspace.items.version
    found = row(workspace, version, value)
    version.rows.readiness[found] == CURRENT || return (cached=false, bytes=nothing)
    bytes = 0
    for (type, key) in store_keys(version.rows.stage[found], version.rows.outputs[found], something(version.rows.stored[found]))
        place = store(workspace, type)
        (place !== nothing && haskey(place, type, key)) || return (cached=false, bytes=nothing)
        bytes += DataBrowserAPI.stored_size(place, type, key)
    end
    return (cached=true, bytes)
end

"""
    revision(workspace, computation) -> UInt

A number that changes when the result of `computation` changes: when it becomes current, or stops
being so. A window keeps the number it drew with, and draws again when it differs. Reading it
computes nothing.
"""
function revision(workspace::Workspace, value::Computation)::UInt
    version = @atomic workspace.items.version
    return revision(version, row(workspace, version, value))
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
argument_id(x::Input) = id(x.computation)
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
    while true
        version = wait_processed(workspace, ids)
        columns, numbers = version.columns, [version.index[x] for x in ids]
        ## Read each value from the store of its type, by its revision. A value missing from its
        ## store is computed again, together with the other values of its catalog row.
        found = kept(workspace, [Tuple{Type,UInt64}[(columns.type[n], columns.value_revision[n])] for n in numbers])
        delivered = AbstractDataItem[only(value) === nothing ? pick(computed!(workspace, columns.version[n]), x) : something(only(value))
            for (value, n, x) in zip(found, numbers, ids)]
        revision(workspace, ids) == revision(version, ids) && return delivered
    end
end

"""
    processed(workspace, ids) -> Bool

Ask for the values `ids` ahead of background work, as `materialize_items` does, and tell whether the
latest version of each is computed now, or failed. The call does not wait, so a window can keep
showing what it showed until the values are ready.
"""
function processed(workspace::Workspace, ids::AbstractVector{<:AbstractString})::Bool
    items = workspace.items
    version = @atomic items.version
    waiting = filter(x -> !(readiness(version, x) in (CURRENT, FAILED)), ids)
    (items.closed || isempty(waiting)) && return true
    ## A request ends with the next publish, so a window asks again at each call.
    @lock items.lock union!(items.requested, waiting)
    notify(items.event)
    return false
end

"""
    wait_processed(workspace, ids) -> Version

Ask for the values `ids` ahead of background work, wait until the latest version of each is
computed, and return the version of the table `items` where they are. A failed value throws its
error. The version follows the workspace as it was when the call started, or later.
"""
function wait_processed(workspace::Workspace, ids::AbstractVector{<:AbstractString})::Version
    items = workspace.items
    ## The latest version of each id when the call last asked for it.
    asked = Dict{String,Row}()
    @lock items.lock try
        push!(items.readers, ids)
        while true
            items.closed && error("The workspace was closed")
            version, waiting, asking = (@atomic items.version), false, false
            for x in ids
                ## The cells of an id follow the catalog once a version is published after the call
                ## asked for it.
                x in items.requested && (waiting = true; continue)
                n = number(version, x)
                if haskey(asked, x)
                    n == 0 && error("The workspace has no value with the id \"$x\"")
                    row = version.columns.version[n]
                    version.rows.readiness[row] == FAILED && error(version.rows.failure[row])
                    version.rows.readiness[row] == CURRENT && continue
                    waiting = true
                    ## A request ends with the next publish: the call asks again when the latest
                    ## version moved to another row, or when nothing wants it.
                    version.rows.readiness[row] == WORKING && row == asked[x] && continue
                end
                push!(items.requested, x)
                asked[x] = n == 0 ? Catalogs.NOWHERE : version.columns.version[n]
                waiting = asking = true
            end
            waiting || return version
            asking && notify(items.event)
            wait(items.published)
        end
    finally
        deleteat!(items.readers, findfirst(isequal(ids), items.readers))
    end
end

"""
    revision(workspace, ids) -> UInt

A number that changes when `materialize_items` would deliver other values for `ids`: a value has a
later version, or its latest version was computed again. A window keeps the number it drew with,
and draws again when it differs.
"""
revision(workspace::Workspace, ids::AbstractVector{<:AbstractString})::UInt = revision((@atomic workspace.items.version), ids)

revision(version::Version, ids::AbstractVector{<:AbstractString})::UInt =
    foldl((seed, x) -> hash(revision(version, cell(version, x, :version, Catalogs.NOWHERE)), seed), ids; init=UInt(0))

# The part of a row in `revision`: it changes when the row becomes current, or stops being so.
revision(version::Version, row::Row)::UInt = row == Catalogs.NOWHERE ? UInt(0) :
    hash(row.index, hash(version.rows.readiness[row] == CURRENT, hash(version.rows.changes[row])))

"""
    work_counts(workspace) -> (completed, total, running)

The jobs that ended, all jobs (ended, running and waiting), and the jobs that run now, as the
workers counted them at the start or the end of the last job. The performance window of the browser
shows them.
"""
work_counts(workspace::Workspace)::Tuple{Int,Int,Int} = @atomic workspace.work
