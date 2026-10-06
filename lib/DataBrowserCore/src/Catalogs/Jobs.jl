# Stage status, invalidation, the job queue, jobs and requests.

# Stages and jobs

# TODO: absent stages. Only the root has them so far, and it has no parent that waits for it. An
# absent stage should become fresh as soon as its inputs are fresh, once the project decides which
# stages exist.

"""
Write the status of one stage of a row that is not removed, and wake the tasks waiting for a
request. The caller holds the lock.

When an item's analyze or a collection's collection analyze turns fresh or stops being fresh, the
counters of the collections that hold it follow. When a stage fails or becomes blocked, the stages
that read it become blocked, and they are unblocked when it recovers.

This is the one place where a status change queues jobs: for the stage itself, and for the stages
that read it when it turns fresh.
"""
function Base.setindex!(catalog::Catalog, new::StageStatus, key::K, stage::PipelineStage) where {K<:RowKey}
    first, second = stages(K)
    old = status(catalog, key, stage)
    table(catalog, key).status[key.index] = stage == first ?
        word(new, status(catalog, key, second)) : word(status(catalog, key, first), new)
    member = stage == ITEM_ANALYZE || stage == COLLECTION_ANALYZE && key != ROOT
    if member
        holder = key isa ItemKey ?
            catalog.items.collection[key.index] : catalog.collections.parent[key.index]
        catalog.collections.not_fresh[holder.index] += (old.validity == FRESH) - (new.validity == FRESH)
        stage == ITEM_ANALYZE &&
            add_nested!(catalog.collections, holder, 0, (new.validity == FRESH) - (old.validity == FRESH))
    end
    stuck = new.failed || new.blocked
    if stuck != (old.failed || old.blocked)
        if member
            add_stuck!(catalog, holder, stuck ? 1 : -1)
        else
            for (next_key, next_stage) in dependents(catalog, key, stage)
                catalog[next_key, next_stage] =
                    StageStatus(status(catalog, next_key, next_stage); blocked=stuck)
            end
        end
    end
    queue!(catalog, key, stage)
    if new.validity == FRESH && old.validity != FRESH
        foreach(next -> queue!(catalog, next...), dependents(catalog, key, stage))
    end
    notify(catalog.changed)
    return catalog
end

"""The stages that read the output of `stage` on `key`."""
function dependents(catalog::Catalog, key::RowKey, stage::PipelineStage)::Vector{Target}
    stage == SOURCE_READ && return Target[(key, SOURCE_EXPAND)]
    stage == SOURCE_EXPAND && return Target[(item, ITEM_PROCESS) for item in items(catalog, key)]
    stage == ITEM_PROCESS && return Target[(key, ITEM_ANALYZE)]
    stage == ITEM_ANALYZE && return Target[(collection(catalog, key), COLLECTION_PROCESS)]
    stage == COLLECTION_PROCESS && return Target[(key, COLLECTION_ANALYZE)]
    key == ROOT && return Target[]
    return Target[(parent(catalog, key), COLLECTION_PROCESS)]
end

"""The stages whose output `stage` on `key` reads. A source item's read reads outside the catalog."""
function inputs(catalog::Catalog, key::RowKey, stage::PipelineStage)::Vector{Target}
    stage == SOURCE_READ && return Target[]
    stage == SOURCE_EXPAND && return Target[(key, SOURCE_READ)]
    stage == ITEM_PROCESS && return Target[(source(catalog, key), SOURCE_EXPAND)]
    stage == ITEM_ANALYZE && return Target[(key, ITEM_PROCESS)]
    stage == COLLECTION_PROCESS && return Target[
        [(item, ITEM_ANALYZE) for item in items(catalog, key)];
        [(child, COLLECTION_ANALYZE) for child in children(catalog, key)]]
    return Target[(key, COLLECTION_PROCESS)]
end

"""
Whether the inputs of `stage` on `key` allow a job for it to start: every input is fresh, and for a
source item, read has not failed.
"""
function ready(catalog::Catalog, key::RowKey, stage::PipelineStage)::Bool
    stage == SOURCE_READ && return true
    stage == SOURCE_EXPAND && return !status(catalog, key, SOURCE_READ).failed
    stage == ITEM_PROCESS &&
        return status(catalog, source(catalog, key), SOURCE_EXPAND).validity == FRESH
    stage == ITEM_ANALYZE && return status(catalog, key, ITEM_PROCESS).validity == FRESH
    stage == COLLECTION_PROCESS && return catalog.collections.not_fresh[key.index] == 0
    return status(catalog, key, COLLECTION_PROCESS).validity == FRESH
end

"""
The stages that one job for `stage` on `key` runs. A source item has one job for its two stages; the
last stage names the job.
"""
jobstages(::SourceKey, ::PipelineStage) = stages(SourceKey)
jobstages(::RowKey, stage::PipelineStage) = (stage,)

"""
Whether a job for `stage` on `key` can start now: the row exists, the stage is not absent, fresh,
failed or running, and its inputs allow it.
"""
function startable(catalog::Catalog, key::RowKey, stage::PipelineStage)::Bool
    key in table(catalog, key) || return false
    old = status(catalog, key, stage)
    (old.absent || old.failed || old.validity == FRESH || old.running) && return false
    # Readiness reads one status or one counter.
    return ready(catalog, key, stage)
end

"""The status of a stage after a job for it whose result is kept."""
finished(old::StageStatus, failed::Bool)::StageStatus = failed ?
    StageStatus(old; running=false, failed=true) :
    StageStatus(old; validity=FRESH, running=false, output=true)

"""
    invalidate!(catalog, key, stage)
    invalidate!(catalog, targets)

Mark `stage` on `key`, or each `(key, stage)` in `targets`, and every stage downstream as stale: the
second stage of the row, the items of a source item, the collection that holds an item, and each
collection up to the root. Every stage reached gets one new revision, so a job running for it
cannot publish, and loses its failure. A stage that was never computed stays missing.

A stage that is wanted is queued once its inputs allow it (see [`take!`](@ref)).
"""
invalidate!(catalog::Catalog, key::RowKey, stage::PipelineStage)::Catalog =
    invalidate!(catalog, [(key, stage)])

function invalidate!(catalog::Catalog, targets::AbstractVector{<:Tuple{Any,PipelineStage}})::Catalog
    @lock catalog.lock begin
        reached = Set{Target}()
        pending = collect(Target, targets)
        while !isempty(pending)
            next = pop!(pending)
            next in reached && continue
            push!(reached, next)
            row, row_stage = next
            row in table(catalog, row) || continue
            old = status(catalog, row, row_stage)
            validity = old.validity == FRESH ? STALE : old.validity
            (old.validity == FRESH || old.failed) && push!(catalog.stale, next)
            catalog[row, row_stage] = StageStatus(old; validity, failed=false, revision=old.revision + 1)
            append!(pending, dependents(catalog, row, row_stage))
        end
    end
    return catalog
end

"""
    stale!(catalog) -> Vector{Target}

The stages that lost a fresh or failed result since the last call, each time it happened, and
`COLLECTION_PROCESS` of each collection that was removed. The caller removes what it saved for
them, so that a saved result is never taken for a current one.
"""
function stale!(catalog::Catalog)::Vector{Target}
    @lock catalog.lock begin
        stale = copy(catalog.stale)
        empty!(catalog.stale)
        return stale
    end
end

"""
    restore!(catalog, key, stage; failed=false, metadata=nothing) -> Bool

Give `stage` on `key` the result that a previous session saved for it: fresh with its output
present, or failed. `metadata` is the metadata an item or collection stage produced. Returns
`false`, and changes nothing, when an input of the stage is not fresh: the saved result was
computed from other inputs.
"""
function restore!(
    catalog::Catalog,
    key::RowKey,
    stage::PipelineStage;
    failed::Bool=false,
    metadata::Union{Nothing,AbstractDict{Symbol}}=nothing,
)::Bool
    @lock catalog.lock begin
        ready(catalog, key, stage) || return false
        metadata === nothing || store!(catalog, key, stage, metadata)
        catalog[key, stage] = finished(status(catalog, key, stage), failed)
        return true
    end
end

"""
The priority of a job for `stage` on `key`, or 0 when nothing wants it. A stage is wanted by the
eager policy of its own stage, unless it is absent, or by any stage that reads its output and is
wanted.
"""
function priority(catalog::Catalog, key::RowKey, stage::PipelineStage)::Int
    rank = status(catalog, key, stage).absent ? 0 : get(catalog.eager, stage, 0)
    requested = get(catalog.requests, (key, stage), nothing)
    requested === nothing || (rank = max(rank, maximum(requested)))
    for (next_key, next_stage) in dependents(catalog, key, stage)
        rank = max(rank, priority(catalog, next_key, next_stage))
    end
    return rank
end

"""
Queue the job for `stage` on `key` if it can start and is wanted. A job already queued at another
priority moves to this one. The caller holds the lock.

A status change queues jobs through `setindex!`. The other callers are those that change what is
wanted or add a row: a new source item or collection, a request, and `take!`.
"""
function queue!(catalog::Catalog, key::RowKey, stage::PipelineStage)::Nothing
    stage = last(jobstages(key, stage))
    # Checked first: priority walks every stage downstream.
    startable(catalog, key, stage) || return nothing
    rank = priority(catalog, key, stage)
    rank > 0 || return nothing
    # A job queued at another priority moves; `take!` skips its old entry.
    get(catalog.queued, (key, stage), 0) == rank && return nothing
    push!(get!(Vector{Target}, catalog.queue, rank), (key, stage))
    catalog.queued[(key, stage)] = rank
    notify(catalog.changed)
    return nothing
end

"""
    take!(catalog) -> Union{Job,Nothing}

Start the queued job with the highest priority and return it, or `nothing` when no job is queued.
Jobs of equal priority start in the order they were queued.

A stage is queued when something wants it and its inputs are fresh. A stage that is wanted but
waits for its inputs is queued when they become fresh. When a stage is invalidated while its job
runs, the job's result is discarded and the stage is queued once more, so a collection whose
members change many times during one run runs again once.
"""
function Base.take!(catalog::Catalog)::Union{Job,Nothing}
    @lock catalog.lock begin
        while !isempty(catalog.queue)
            rank = maximum(keys(catalog.queue))
            bucket = catalog.queue[rank]
            target = popfirst!(bucket)
            isempty(bucket) && delete!(catalog.queue, rank)
            get(catalog.queued, target, 0) == rank || continue
            delete!(catalog.queued, target)
            key, stage = target
            key in table(catalog, key) || continue
            # While the stage waited, its inputs or what wants it may have changed. `start!` refuses
            # a stage that became fresh, failed or running meanwhile.
            if !ready(catalog, key, stage) || priority(catalog, key, stage) != rank
                queue!(catalog, key, stage)
                continue
            end
            job = start!(catalog, key, stage)
            job === nothing || return job
        end
        return nothing
    end
end

"""
A running job: one stage of one row, and the revision of the inputs it started from. A source
item's job runs both of its stages and holds the revision of expand, which every change to read
also increases.
"""
mutable struct Job{K<:RowKey}
    const key::K
    const stage::PipelineStage
    const revision::UInt32
    finished::Bool
end

Job(key::RowKey, stage::PipelineStage, revision::UInt32) = Job(key, stage, revision, false)

"""
    start!(catalog, key, stage) -> Union{Job,Nothing}
    start!(catalog, source::SourceKey) -> Union{Job,Nothing}

Mark `stage` on `key` as running and return its job. Returns `nothing` when the stage cannot run
now: the row was removed, or the stage is absent, fresh, failed or already running, or one of its
inputs is not fresh.

A source item has one job for its two stages: it runs read, unless read is fresh, and then expand.
It returns `nothing` when expand is fresh, either stage failed, or the job is already running.
"""
function start!(catalog::Catalog, key::K, stage::PipelineStage)::Union{Job{K},Nothing} where {K<:RowKey}
    @lock catalog.lock begin
        stage = last(jobstages(key, stage))
        startable(catalog, key, stage) || return nothing
        # The stage that names the job is marked first, so that marking the other does not queue it.
        for part in reverse(jobstages(key, stage))
            old = status(catalog, key, part)
            old.validity == FRESH || (catalog[key, part] = StageStatus(old; running=true))
        end
        return Job(key, stage, status(catalog, key, stage).revision)
    end
end

start!(catalog::Catalog, source::SourceKey) = start!(catalog, source, SOURCE_EXPAND)

"""
    iscurrent(catalog, job) -> Bool

Whether the result of `job` would be kept now: its row exists and its stage was not invalidated
since the job started. A job checks this before it saves a large result.
"""
iscurrent(catalog::Catalog, job::Job)::Bool = @lock catalog.lock (
    !job.finished && job.key in table(catalog, job.key) &&
    status(catalog, job.key, job.stage).revision == job.revision)

"""The number of jobs that wait in the queue."""
queued(catalog::Catalog)::Int = @lock catalog.lock length(catalog.queued)

"""
Mark `job` as finished and return whether its result is kept: its row exists and its stage was not
invalidated while it ran. When the result is discarded, the job's stages stop running and the job
is queued again. The caller holds the lock.
"""
function claim!(catalog::Catalog, job::Job)::Bool
    job.finished && throw(ArgumentError("the job has already finished"))
    job.finished = true
    job.key in table(catalog, job.key) || return false
    status(catalog, job.key, job.stage).revision == job.revision && return true
    for stage in jobstages(job.key, job.stage)
        old = status(catalog, job.key, stage)
        old.running && (catalog[job.key, stage] = StageStatus(old; running=false))
    end
    return false
end

"""
The status of a source item's two stages after a job whose result is kept. `failed` names the stage
that failed, or is `nothing`. When read fails, expand fails with it. The caller holds the lock.
"""
function settle!(catalog::Catalog, job::Job{SourceKey}, failed::Union{PipelineStage,Nothing})
    # Expand is read after read is written, which can block it.
    for (stage, stage_failed) in (SOURCE_READ => failed == SOURCE_READ, SOURCE_EXPAND => failed !== nothing)
        catalog[job.key, stage] = finished(status(catalog, job.key, stage), stage_failed)
    end
    return nothing
end

"""
    finish!(catalog, job; failed=false, metadata=MetadataDict()) -> Bool
    finish!(catalog, source_job, entries) -> Bool
    finish!(catalog, source_job; failed=stage) -> Bool

End a job. A job finishes once; a second `finish!` throws an `ArgumentError`. If the job's stage was
not invalidated while it ran, the stage becomes fresh with its output present, or failed when
`failed` is true, and `finish!` returns `true`. A successful item or collection job stores the
`metadata` it produced, in place of that stage's previous metadata. Otherwise the result is discarded, the stage stays
stale, and `finish!` returns `false`.

A source item's job passes the `entries` it produced. They are published as by
[`publish!`](@ref) only when the result is kept. Entries that `publish!` refuses fail expand and
throw the error. A failed source job names the stage that failed: `SOURCE_READ` fails both stages,
and `SOURCE_EXPAND` keeps read fresh.
"""
function finish!(
    catalog::Catalog,
    job::Job{<:Union{ItemKey,CollectionKey}};
    failed::Bool=false,
    metadata::AbstractDict{Symbol}=MetadataDict(),
)::Bool
    @lock catalog.lock begin
        claim!(catalog, job) || return false
        failed || store!(catalog, job.key, job.stage, metadata)
        catalog[job.key, job.stage] = finished(status(catalog, job.key, job.stage), failed)
        return true
    end
end

function finish!(catalog::Catalog, job::Job{SourceKey}, entries::AbstractVector{ItemEntry})::Bool
    @lock catalog.lock begin
        claim!(catalog, job) || return false
        try
            publish!(catalog, job.key, entries)
        catch
            settle!(catalog, job, SOURCE_EXPAND)
            rethrow()
        end
        settle!(catalog, job, nothing)
        return true
    end
end

function finish!(catalog::Catalog, job::Job{SourceKey}; failed::PipelineStage)::Bool
    failed in stages(SourceKey) || throw(ArgumentError("a source item has no $failed stage"))
    @lock catalog.lock begin
        claim!(catalog, job) || return false
        settle!(catalog, job, failed)
        return true
    end
end

# Requests

"""
A request for one stage of one row, made by [`request`](@ref). Wait for the stage with `wait`, and
withdraw the request with `close`.
"""
mutable struct Request
    const catalog::Catalog
    const key::RowKey
    const stage::PipelineStage
    const priority::Int
    open::Bool
end

"""
    request(catalog, key, stage; priority=1) -> Request

Ask for `stage` on `key` to become fresh. Jobs for the stage, and for the stages it reads that are
not fresh, run at `priority` or higher. A stage with several requests takes the highest priority
among them. The request stays open until `close`.

Throws an `ArgumentError` when `priority` is not positive, the row was removed, or the stage is
absent.
"""
function request(catalog::Catalog, key::RowKey, stage::PipelineStage; priority::Int=1)::Request
    priority > 0 || throw(ArgumentError("a priority must be positive"))
    @lock catalog.lock begin
        key in table(catalog, key) || throw(ArgumentError("the row was removed"))
        status(catalog, key, stage).absent && throw(ArgumentError("the $stage stage is absent here"))
        target = (key, last(jobstages(key, stage)))
        push!(get!(Vector{Int}, catalog.requests, target), priority)
        # Queue every stage on the way that is not fresh. Those whose inputs are not fresh yet are
        # queued when their inputs finish.
        reached = Set{Target}()
        pending = Target[target]
        while !isempty(pending)
            next = pop!(pending)
            next in reached && continue
            push!(reached, next)
            status(catalog, next...).validity == FRESH && continue
            queue!(catalog, next...)
            # A stage that is ready has only fresh inputs.
            ready(catalog, next...) || append!(pending, inputs(catalog, next...))
        end
        return Request(catalog, key, stage, priority, true)
    end
end

"""Whether a stage has stopped changing until something invalidates it: fresh, failed, blocked or removed."""
settled(status::StageStatus)::Bool =
    status.validity in (FRESH, REMOVED) || status.failed || status.blocked

"""
    wait(request) -> StageStatus

Block until the requested stage settles, and return its status. A stage settles when it is fresh,
failed, blocked by an input that failed, or removed. `wait` also returns when the request is closed.
"""
function Base.wait(request::Request)::StageStatus
    catalog = request.catalog
    @lock catalog.lock while true
        current = status(catalog, request.key, request.stage)
        (settled(current) || !request.open) && return current
        wait(catalog.changed)
    end
end

"""
    close(request)

Withdraw a request. A queued job that no other request and no eager stage needs is skipped when
`take!` reaches it; a running job finishes. Tasks waiting on the request return.
"""
function Base.close(request::Request)::Nothing
    catalog = request.catalog
    @lock catalog.lock begin
        request.open || return nothing
        request.open = false
        target = (request.key, last(jobstages(request.key, request.stage)))
        priorities = catalog.requests[target]
        deleteat!(priorities, findfirst(==(request.priority), priorities))
        isempty(priorities) && delete!(catalog.requests, target)
        notify(catalog.changed)
    end
    return nothing
end
