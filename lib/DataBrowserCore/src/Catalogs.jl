"""
Rows of a workspace: source items, items and collections, with their keys, public ids, labels,
membership and the status of each stage.
"""
module Catalogs

using ..DataBrowserCore: Computation

import DataBrowserAPI: id, items, label, metadata
using DataBrowserAPI:
    AbstractCollection,
    AbstractDataItem,
    PipelineStage,
    SOURCE_READ,
    SOURCE_EXPAND,
    ITEM_PROCESS,
    COLLECTION_PROCESS,
    MEMBER_PROCESS,
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

"""
The stages of a row of kind `K`, in the halves of its status word from the lower one up: a source
item has read and expand, an item has its process and the member process of the collections above
it, and a collection has its process.
"""
stages(::Type{SourceKey}) = (SOURCE_READ, SOURCE_EXPAND)
stages(::Type{ItemKey}) = (ITEM_PROCESS, MEMBER_PROCESS)
stages(::Type{CollectionKey}) = (COLLECTION_PROCESS,)

include("Catalogs/Columns.jl")
include("Catalogs/Rows.jl")
include("Catalogs/Jobs.jl")

end
