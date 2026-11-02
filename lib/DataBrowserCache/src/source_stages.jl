"""Record a discovered source item's identity and fingerprint."""
function store_source_identity!(
    cache::CacheDB, item::AbstractDataSourceItem, display_label::AbstractString=label(item),
)::Nothing
    source_key = source_item_key!(cache, id(item); mint=true)
    edit!(cache.source_items, id(item), SourceItemRow(
        id(item), source_key, String(display_label), _serialize_hex(fingerprint(item))))
    return nothing
end

"""Delete a source identity and everything the cache saved for its items."""
function delete_source_item!(cache::CacheDB, source_key::Integer,
        item_ids::Vector{String})::Nothing
    delete_source_output!(cache, source_key, item_ids)
    _delete_source_identity!(cache, Int64(source_key))
    return nothing
end

function _delete_source_identity!(cache::CacheDB, source_key::Int64)::Nothing
    delete!(cache.source_items, source_item_id(cache, source_key))
    return nothing
end
