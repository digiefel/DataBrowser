"""
The data sources that DataBrowser provides. [`DirectorySource`](@ref) reads the files of a folder.
"""
module DataBrowserSources

using DataBrowserAPI

include("directory_source.jl")

export DirectorySource, SourceFile

end
