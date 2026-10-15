"""
Tags and notes persistence keyed on item and collection IDs.
"""
module DataBrowserAnnotations

using DataBrowserAPI: AbstractDataItem

include("identity.jl")
include("tags.jl")
include("notes.jl")

export Tags, Notes
export AnnotationKey, item_annotation_key, collection_annotation_key, ancestor_annotation_keys

end # module
