"""
Files in which the user annotates items and collections: [`Tags`](@ref) in `tags.txt` and
[`Notes`](@ref) in `notes.txt`. Both name an item by its id, and a collection by the labels of the
collections from the top down, joined with `/`.
"""
module DataBrowserAnnotations

include("tags.jl")
include("notes.jl")

export Tags, Notes

end # module
