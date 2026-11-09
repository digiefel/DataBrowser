"""
The cache of a workspace, a DuckDB file that saves a record of each computation for the next
session, and the stores that keep the results of computations: `MemoryStore` and `DuckDBStore`.
"""
module DataBrowserCache

import DataBrowserAPI
using DataBrowserAPI: metadata_dict, id, metadata, label
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

export BuildMetrics,
    MemoryStore,
    DuckDBStore,
    CacheDB,
    ProjectCacheError,
    ProjectCacheSchemaError,
    ProjectCacheIdentity,
    SavedOutput,
    cache_has_pending_writes,
    cache_pending_counts,
    close_cache_db!,
    key!,
    open_cache_db,
    output_key!,
    project_cache_identity,
    query_items,
    record_cache_phase!,
    reset_build_metrics!,
    set_cache_memory_limit!

end
