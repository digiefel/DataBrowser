module DataBrowserCacheDataFramesExt

using DataBrowserCache, DataFrames

# `DataFrame(columns)` copies each column by default, which doubles the memory a read fills.
DataBrowserCache.materialized(::Type{<:DataFrame}, columns) = DataFrame(columns; copycols=false)

end
