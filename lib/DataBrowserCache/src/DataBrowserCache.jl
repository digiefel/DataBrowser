"""DuckDB cache buffers, build metrics, and project cache domain."""
module DataBrowserCache

import DataBrowserAPI
import DataBrowserAPI: label
using DataBrowserAPI:
    AbstractCollection,
    AbstractDataSourceItem,
    MetadataDict,
    MetadataValue,
    metadata_dict,
    PipelineStage,
    SOURCE_READ,
    SOURCE_EXPAND,
    ITEM_PROCESS,
    ITEM_ANALYZE,
    COLLECTION_PROCESS,
    COLLECTION_ANALYZE,
    fingerprint,
    id,
    metadata,
    label
using DataBrowserAPI: @timed_dbg

using DuckDB
using DBInterface
import Tables
using Serialization
using Dates

include("build_metrics.jl")
include("cache_buffer.jl")
include("project_cache_domain.jl")
include("source_stages.jl")

export BuildMetrics,
    CacheResultKey,
    CacheResultStatus,
    CacheDB,
    CacheStageSummary,
    ProjectCacheError,
    ProjectCacheSchemaError,
    ProjectCacheDataError,
    ProjectCacheIdentity,
    ProjectCacheIndex,
    ProjectCacheStatus,
    RESULT_FAILED,
    RESULT_READY,
    cache_stage_summary,
    cache_has_pending_writes,
    cache_pending_counts,
    cached_result_state,
    cached_source_fingerprints,
    clear_cache_index!,
    clear_cached_result_state!,
    close_cache_db!,
    delete_collection_records!,
    delete_processed!,
    delete_collection_metadata!,
    delete_source_item!,
    delete_source_output!,
    has_payload,
    load_cache_index,
    open_cache_db,
    project_cache_identity,
    query_items,
    read_payload,
    record_cache_phase!,
    reset_build_metrics!,
    set_cache_memory_limit!,
    store_collection_metadata!,
    store_collection!,
    store_collection_process_result!,
    store_item!,
    store_item_payload!,
    store_item_label!,
    store_item_metadata!,
    store_item_metadata_layer!,
    store_processed!,
    store_result_failure!,
    store_source_identity!,
    store_source_read!,
    store_source_result!,
    source_complete,
    cache_knows_source,
    edit_source_item_metadata!,
    source_item_key!,
    source_item_key,
    source_item_id

end
