"""
Files in which the user annotates items: [`Tags`](@ref) in `tags.txt` and [`Notes`](@ref) in
`notes.txt`. Both name an item by its id.
"""
module DataBrowserAnnotations

include("tags.jl")
include("notes.jl")

export Tags, Notes

end # module
