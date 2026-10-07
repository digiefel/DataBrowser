"""
Concrete data sources: directory scanning.
"""
module DataBrowserSources

using DataBrowserAPI

include("directory_source.jl")

export DirectorySource, SourceFile

end
