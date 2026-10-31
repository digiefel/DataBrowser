"""Record a discovered source item's identity and fingerprint, independently of its stage results."""
function store_source_identity!(
    cache::CacheDB, item::AbstractDataSourceItem, display_label::AbstractString=label(item),
)::Nothing
    source_key = source_item_key!(cache, id(item); mint=true)
    edit!(cache.source_items, id(item), SourceItemRow(
        id(item), source_key, String(display_label), _serialize_hex(fingerprint(item))))
    _stage_ledger_source!(cache.stage_ledger, source_key, true)
    return nothing
end

"""Record successful completion of a source stage after publishing its output."""
function store_source_result!(cache::CacheDB, stage::PipelineStage, source_key::Int64)::Nothing
    state = CachedKeyedResultState(Int8(stage), source_key, Int8(RESULT_READY), source_key, nothing)
    edit!(cache.keyed_result_states, (Int8(stage), source_key), state)
    _stage_ledger_result!(cache.stage_ledger, (Int8(stage), source_key), state)
    return nothing
end

"""Whether a source has published its items or failed at either source stage."""
function source_complete(cache::CacheDB, source_key::Integer)::Bool
    items = cached_result_state(cache, SOURCE_EXPAND, source_key)
    items === nothing || return true
    loaded = cached_result_state(cache, SOURCE_READ, source_key)
    return loaded !== nothing && CacheResultStatus(loaded.status) === RESULT_FAILED
end

"""Whether the cache knows a source identity, including an unfinished or failed source."""
function cache_knows_source(cache::CacheDB, source_key::Integer)::Bool
    return lock(cache.stage_ledger.lock) do
        Int64(source_key) in cache.stage_ledger.source_items
    end
end

"""Delete a source identity and all its stage results."""
function delete_source_item!(cache::CacheDB, source_key::Integer,
        item_ids::Vector{String})::Nothing
    delete_source_output!(cache, source_key, item_ids)
    clear_cached_result_state!(cache, SOURCE_READ, source_key)
    _delete_source_identity!(cache, Int64(source_key))
    _stage_ledger_source!(cache.stage_ledger, source_key, false)
    return nothing
end

function _delete_source_identity!(cache::CacheDB, source_key::Int64)::Nothing
    delete!(cache.source_items, source_item_id(cache, source_key))
    return nothing
end
