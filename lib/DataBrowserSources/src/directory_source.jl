using BetterFileWatching
using CancellationTokens: CancellationToken, CancellationTokenSource, OperationCanceledException, cancel, get_token, is_cancellation_requested

using DataBrowserAPI:
    AbstractDataSource,
    AbstractDataSourceItem,
    SourceChanges,
    SourceError
import DataBrowserAPI:
    close_source!,
    fingerprint,
    id,
    label,
    members,
    metadata,
    open_source,
    items,
    watch_source

# Files that DataBrowser keeps in the folder of a source. They are never source files.
# TODO: delete this list. Tags, notes and the saved view move beside the project, one set per
# project (roadmap 0.15.0).
const DIRECTORY_SOURCE_SIDECARS = Set(["tags.txt", "notes.txt", "databrowser.toml"])

"""
Fingerprint used to decide whether a physical source file has changed.
"""
struct FileFingerprint
    path::String
    size_bytes::Int64
    mtime_ns::Int64
end

"""
    DirectorySource(root_path; recursive=true)

A data source that reads the files in the folder `root_path`. Each file is one source item, a
[`SourceFile`](@ref), and the folder is one too, a [`SourceDirectory`](@ref) whose members are the
files in it. With `recursive=true`, the files and folders below `root_path` are source items too,
and the members of each folder are the files and folders directly in it. An empty folder is not a
source item.

Hidden files and folders, whose names start with `.`, are not source items. Nor are the files that
DataBrowser keeps in a folder: `tags.txt`, `notes.txt` and `databrowser.toml`, in upper or lower
case.

While a workspace has the source open, the source watches the folder. It reports files and folders
that are added, changed or removed. A folder changes when a member is added or removed.
"""
mutable struct DirectorySource <: AbstractDataSource
    root_path::String
    recursive::Bool
    watcher_task::Union{Nothing,Task}
    watcher_cancel::Union{Nothing,CancellationTokenSource}
end

function DirectorySource(root_path::AbstractString; recursive::Bool=true)::DirectorySource
    # `dirname(joinpath(path, ""))` removes a trailing `/`. With it, the same folder would have
    # another id, and so another cache.
    root = dirname(joinpath(abspath(expanduser(root_path)), ""))
    return DirectorySource(root, recursive, nothing, nothing)
end

"""
One file of a [`DirectorySource`](@ref).

`filepath` is the absolute path of the file, and `filename` is its name with the extension.
`relative_path` is the path below the folder of the source. It is the `id` and the `label` of the
file. The metadata of the file is its `:filename`.
"""
struct SourceFile <: AbstractDataSourceItem
    filepath::String
    filename::String
    relative_path::String
    fingerprint::FileFingerprint
end

# Identity is the path relative to the source root, not the absolute one: it is unique within the
# source, short enough to show as-is, and unchanged when the directory is moved or copied.
id(file::SourceFile)::String = file.relative_path
label(file::SourceFile)::String = file.relative_path
fingerprint(file::SourceFile)::FileFingerprint = file.fingerprint
metadata(file::SourceFile)::Dict = Dict{Symbol,Any}(:filename => file.filename)

"""
One folder of a [`DirectorySource`](@ref): the folder of the source, or, with `recursive=true`, a
folder below it. Its [`members`](@ref) are the source items directly in it.

`path` is the absolute path of the folder. `relative_path` is its path below the folder of the
source, `"."` for the folder of the source itself. It is the `id` and the `label` of the folder.
"""
struct SourceDirectory <: AbstractDataSourceItem
    path::String
    relative_path::String
    members::Vector{AbstractDataSourceItem}
end

id(directory::SourceDirectory)::String = directory.relative_path
label(directory::SourceDirectory)::String = directory.relative_path
# A folder changes when a member is added, removed or renamed, not when a member changes. Each id is
# hashed in turn: the `hash` of a long vector reads only some of its elements.
fingerprint(directory::SourceDirectory)::UInt64 = foldl((h, member) -> hash(id(member), h), directory.members; init=UInt64(0))
members(::DirectorySource, directory::SourceDirectory)::Vector{AbstractDataSourceItem} = directory.members

id(source::DirectorySource)::String = source.root_path
label(source::DirectorySource)::String = basename(source.root_path)

"""
    index_source_file(path, root) -> SourceFile

The source item of the file at `path`, identified by its path relative to the folder `root`.
"""
function index_source_file(path::AbstractString, root::AbstractString)::SourceFile
    filepath = abspath(expanduser(path))
    info = stat(filepath)
    return SourceFile(
        filepath,
        basename(filepath),
        relpath(filepath, expanduser(root)),
        FileFingerprint(filepath, info.size, Int64(info.mtime * 1_000_000_000)),
    )
end

function items(
    source::DirectorySource;
    on_progress::Union{Nothing,Function}=nothing,
    on_item::Union{Nothing,Function}=nothing,
    cancel_token::CancellationToken,
)::Vector{AbstractDataSourceItem}
    found = AbstractDataSourceItem[]
    function report(item::AbstractDataSourceItem)
        push!(found, item)
        on_item === nothing || on_item(item)
        on_progress !== nothing && length(found) % 256 == 0 && on_progress(length(found))
        return item
    end
    # A folder is reported after its members, so that its members are complete when it is. An empty
    # folder holds nothing, so it is not a source item.
    function scan(folder::String)::Union{Nothing,SourceDirectory}
        folder_members = AbstractDataSourceItem[]
        for name in readdir(folder)
            is_cancellation_requested(cancel_token) && throw(OperationCanceledException(cancel_token))
            # Hidden files and folders, such as `.git`, hold no source files.
            startswith(name, ".") && continue
            path = joinpath(folder, name)
            # A link to a folder can point to a folder above it, so links are not followed.
            if isdir(path) && source.recursive && !islink(path)
                directory = scan(path)
                directory === nothing || push!(folder_members, directory)
            elseif isfile(path) && !(lowercase(name) in DIRECTORY_SOURCE_SIDECARS)
                push!(folder_members, report(index_source_file(path, source.root_path)))
            end
        end
        isempty(folder_members) && return nothing
        return report(SourceDirectory(folder, relpath(folder, source.root_path), folder_members))
    end
    scan(source.root_path)
    on_progress === nothing || on_progress(length(found))
    return found
end

function open_source(source::DirectorySource)::DirectorySource
    isdir(source.root_path) || throw(ArgumentError(
        "Cannot open DirectorySource '$(source.root_path)': directory does not exist",
    ))
    return source
end

function watch_source(
    source::DirectorySource,
    on_change::Function;
    cancel_token::CancellationToken,
)::Task
    source.watcher_task === nothing || error(
        "DirectorySource '$(source.root_path)' is already being watched",
    )
    cancel_source = CancellationTokenSource(cancel_token)
    watch_token = get_token(cancel_source)
    # Typed, as the watcher replaces it: a captured variable that changes is otherwise of unknown type.
    known::Dict{String,Any} = Dict(id(item) => fingerprint(item) for item in items(source; cancel_token=watch_token))
    # Ignore what `items` does not read: hidden files and folders, and the folders below a source
    # that is not recursive.
    ignore(path::AbstractString)::Bool =
        any(startswith('.'), split(path, '/')) || (!source.recursive && occursin('/', path))
    task = Base.Threads.@spawn begin
        try
            watch_folder(source.root_path, watch_token; ignore) do _
                is_cancellation_requested(watch_token) && return
                found = items(source; cancel_token=watch_token)
                is_cancellation_requested(watch_token) && return
                current = Dict(id(item) => fingerprint(item) for item in found)
                upserts = AbstractDataSourceItem[item for item in found if !isequal(get(known, id(item), nothing), fingerprint(item))]
                removals = String[item_id for item_id in keys(known) if !haskey(current, item_id)]
                isempty(upserts) && isempty(removals) && return
                known = current
                on_change(SourceChanges(upserts, removals))
            end
        catch error
            error isa OperationCanceledException && return
            on_change(SourceError(sprint(showerror, error)))
        end
    end
    source.watcher_task = task
    source.watcher_cancel = cancel_source
    return task
end

"""
    copy(source::DirectorySource) -> DirectorySource

Unopened directory source with the same root and scan depth. Does not copy the watcher.
"""
Base.copy(source::DirectorySource) = DirectorySource(source.root_path; recursive=source.recursive)

function close_source!(source::DirectorySource)::Nothing
    source.watcher_cancel === nothing || cancel(source.watcher_cancel)
    # The task reports its own errors through `on_change`, so waiting for it does not throw.
    source.watcher_task === nothing || wait(source.watcher_task)
    source.watcher_task = nothing
    source.watcher_cancel = nothing
    return nothing
end
