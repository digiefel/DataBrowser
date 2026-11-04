"""DuckDB cache buffers, build metrics, and project cache domain."""
module DataBrowserCache

import DataBrowserAPI
import DataBrowserAPI: label
using DataBrowserAPI:
    AbstractDataSourceItem,
    metadata_dict,
    fingerprint,
    id,
    metadata,
    label
using DataBrowserAPI: @timed_dbg

using DuckDB
using OrderedCollections: OrderedDict
using DBInterface
import Tables
using Serialization
using Dates
import StructUtils

include("build_metrics.jl")
include("cache_buffer.jl")
include("MemoryStore.jl")
include("DuckDBStore.jl")
include("project_cache_domain.jl")
include("source_stages.jl")

export BuildMetrics,
    MemoryStore,
    DuckDBStore,
    CacheDB,
    ProjectCacheError,
    ProjectCacheSchemaError,
    ProjectCacheIdentity,
    ProjectCacheIndex,
    cache_has_pending_writes,
    cache_pending_counts,
    clear_cache_index!,
    close_cache_db!,
    delete_source_item!,
    delete_source_output!,
    load_cache_index,
    open_cache_db,
    project_cache_identity,
    query_items,
    replace_source_output!,
    ItemOutput,
    record_cache_phase!,
    reset_build_metrics!,
    set_cache_memory_limit!,
    store_computation_revision!,
    delete_computation_revision!,
    recorded_revision,
    store_item_label!,
    store_item_metadata!,
    store_item_stage_metadata!,
    store_source_identity!,
    source_item_key!,
    source_item_key,
    source_item_id

end
