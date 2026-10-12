"""
Rows of a workspace: source items, items and collections, with their keys, public ids, labels,
membership and the status of each stage.
"""
module Catalogs

import DataBrowserAPI: id, items, label, metadata
using DataBrowserAPI:
    AbstractCollection,
    AbstractDataItem,
    MetadataDict,
    PipelineStage,
    SOURCE_READ,
    SOURCE_EXPAND,
    ITEM_PROCESS,
    ITEM_ANALYZE,
    COLLECTION_PROCESS,
    COLLECTION_ANALYZE,
    metadata_dict

# Keys

"""Key of a source-item row: its position in the source-item table. Never reused."""
struct SourceKey
    index::Int32
end

"""Key of an item row: its position in the item table. Never reused."""
struct ItemKey
    index::Int32
end

"""Key of a collection row: its position in the collection table. Never reused."""
struct CollectionKey
    index::Int32
end

const RowKey = Union{SourceKey,ItemKey,CollectionKey}

"""One stage of one row."""
const Target = Tuple{RowKey,PipelineStage}

"""The root collection: it holds the items and top-level collections that have no other."""
const ROOT = CollectionKey(1)

"""The two stages of a row of kind `K`: the first lives in the lower half of its status word."""
stages(::Type{SourceKey}) = (SOURCE_READ, SOURCE_EXPAND)
stages(::Type{ItemKey}) = (ITEM_PROCESS, ITEM_ANALYZE)
stages(::Type{CollectionKey}) = (COLLECTION_PROCESS, COLLECTION_ANALYZE)

include("Catalogs/Columns.jl")
include("Catalogs/Rows.jl")
include("Catalogs/Jobs.jl")

end
