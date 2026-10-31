using BetterFileWatching
using CancellationTokens: CancellationToken, CancellationTokenSource, OperationCanceledException, cancel, get_token, is_cancellation_requested

import DataBrowserAPI
import DataBrowserAPI: collection, reconstruct
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
[`SourceFile`](@ref). With `recursive=true`, the files in the folders below `root_path` are source
items too, and the folders of a file are its collections, from the top down.

Hidden files and folders, whose names start with `.`, are not source items. Nor are the files that
DataBrowser keeps in a folder: `tags.txt`, `notes.txt` and `databrowser.toml`, in upper or lower
case.

While a workspace has the source open, the source watches the folder. It reports files that are
added, changed or removed.
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

"""One collection level of a directory tree, identified by the directory's name."""
struct DirectoryCollection <: DataBrowserAPI.AbstractCollection
    name::String
end

id(level::DirectoryCollection)::String = level.name
label(level::DirectoryCollection)::String = level.name
label(::Type{DirectoryCollection})::Symbol = :folder
reconstruct(::Type{DirectoryCollection}, identity::AbstractString, ::Dict) =
    DirectoryCollection(String(identity))

"""The folders of a file, from the top down, below the folder of the source."""
function collection(file::SourceFile)::Vector{DataBrowserAPI.AbstractCollection}
    # A file at the root has the directory "", which `splitpath` returns as one empty name.
    return DataBrowserAPI.AbstractCollection[
        DirectoryCollection(name) for name in splitpath(dirname(file.relative_path)) if !isempty(name)]
end

function items(
    source::DirectorySource;
    on_progress::Union{Nothing,Function}=nothing,
    on_item::Union{Nothing,Function}=nothing,
    cancel_token::CancellationToken,
)::Vector{SourceFile}
    files = SourceFile[]
    folders = [source.root_path]
    while !isempty(folders)
        folder = popfirst!(folders)
        for name in readdir(folder)
            is_cancellation_requested(cancel_token) && throw(OperationCanceledException(cancel_token))
            # Hidden files and folders, such as `.git`, hold no source files.
            startswith(name, ".") && continue
            path = joinpath(folder, name)
            if isdir(path)
                # A link to a folder can point to a folder above it, so links are not followed.
                source.recursive && !islink(path) && push!(folders, path)
            elseif isfile(path) && !(lowercase(name) in DIRECTORY_SOURCE_SIDECARS)
                file = index_source_file(path, source.root_path)
                push!(files, file)
                on_item === nothing || on_item(file)
                on_progress !== nothing && length(files) % 256 == 0 && on_progress(length(files))
            end
        end
    end
    on_progress === nothing || on_progress(length(files))
    return files
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
    known = Dict(id(file) => fingerprint(file) for file in items(source; cancel_token=watch_token))
    # Ignore what `items` does not read: hidden files and folders, and the folders below a source
    # that is not recursive.
    ignore(path::AbstractString)::Bool =
        any(startswith('.'), split(path, '/')) || (!source.recursive && occursin('/', path))
    task = Base.Threads.@spawn begin
        try
            watch_folder(source.root_path, watch_token; ignore) do _
                is_cancellation_requested(watch_token) && return
                files = items(source; cancel_token=watch_token)
                is_cancellation_requested(watch_token) && return
                current = Dict(id(file) => fingerprint(file) for file in files)
                upserts = SourceFile[
                    file for file in files
                    if !haskey(known, id(file)) ||
                       !isequal(known[id(file)], fingerprint(file))
                ]
                removals = String[file_id for file_id in keys(known) if !haskey(current, file_id)]
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
