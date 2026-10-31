using Dates
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

const DEFAULT_DIRECTORY_METADATA_FILE = "metadata.txt"

# Files that DataBrowser keeps in the folder of a source. They are never source files.
# TODO: delete this list. Tags, notes and the saved view move beside the project, one set per
# project (roadmap 0.15.0), and `metadata.txt` gives way to the source's `metadata` method.
const DIRECTORY_SOURCE_SIDECARS = Set([
    DEFAULT_DIRECTORY_METADATA_FILE,
    "tags.txt",
    "notes.txt",
    "databrowser.toml",
])

"""The rows of a metadata file: the folder names in the first column, and the metadata of the row."""
const MetadataEntries = Dict{Tuple{Vararg{String}},Dict{Symbol,Any}}

"""
Fingerprint used to decide whether a physical source file has changed.
"""
struct FileFingerprint
    path::String
    size_bytes::Int64
    mtime_ns::Int64
end

"""
    DirectorySource(root_path; recursive=true, metadata_file="metadata.txt")

A data source that reads the files in the folder `root_path`. Each file is one source item, a
[`SourceFile`](@ref). With `recursive=true`, the files in the folders below `root_path` are source
items too, and the folders of a file are its collections, from the top down.

Hidden files and folders, whose names start with `.`, are not source items. Nor are the metadata
file and the files that DataBrowser keeps in a folder: `metadata.txt`, `tags.txt`, `notes.txt` and
`databrowser.toml`, in upper or lower case.

The metadata file, at `metadata_file` relative to `root_path`, gives metadata to folders. Its
first row names the columns. In each further row, the first column names a folder, and each other
column gives the value of one metadata key:

    folder,temperature_K,operator
    A9,300,Ada
    A9/VI,4,

A row names a folder by the last names of its path: `A9` is every folder called `A9`, and `A9/VI`
is every folder `VI` inside a folder `A9`. When several rows name one folder, the row with more
names gives the value of a key that both rows give. An empty cell gives no value, and cells cannot
contain commas. The items below a folder have its metadata.

A value is read as `true` (`true`, `t`, `yes`, `y`) or `false` (`false`, `f`, `no`, `n`), in upper
or lower case; as an `Int`; as a `Float64`; as a `Date` (`2025-10-01` or `2025/10/01`); as a
`DateTime` (`2025-10-01 17:12:33` or `2025-10-01T17:12:33`); and otherwise as text. Use
`metadata_file=nothing` for a source without a metadata file.

While a workspace has the source open, the source watches the folder. It reports files that are
added, changed or removed, and changes to the metadata file.
"""
mutable struct DirectorySource <: AbstractDataSource
    root_path::String
    recursive::Bool
    metadata_file::Union{Nothing,String}
    collection_metadata_entries::MetadataEntries
    has_metadata::Bool
    metadata_lock::ReentrantLock
    watcher_task::Union{Nothing,Task}
    watcher_cancel::Union{Nothing,CancellationTokenSource}
end

function DirectorySource(
    root_path::AbstractString;
    recursive::Bool=true,
    metadata_file::Union{Nothing,AbstractString}=DEFAULT_DIRECTORY_METADATA_FILE,
)::DirectorySource
    # `dirname(joinpath(path, ""))` removes a trailing `/`. With it, the same folder would have
    # another id, and so another cache.
    root = dirname(joinpath(abspath(expanduser(root_path)), ""))
    return DirectorySource(
        root,
        recursive,
        metadata_file === nothing ? nothing : String(metadata_file),
        MetadataEntries(),
        false,
        ReentrantLock(),
        nothing,
        nothing,
    )
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

function parse_metadata_value(text::AbstractString)::Any
    value = strip(text)
    isempty(value) && return nothing
    lowercase_value = lowercase(value)
    lowercase_value in ("true", "t", "yes", "y") && return true
    lowercase_value in ("false", "f", "no", "n") && return false
    for type in (Int, Float64)
        parsed = tryparse(type, value)
        parsed === nothing || return parsed
    end
    for format in (dateformat"yyyy-mm-dd", dateformat"yyyy/mm/dd")
        parsed = tryparse(Date, value, format)
        parsed === nothing || return parsed
    end
    for format in (
        dateformat"yyyy-mm-dd HH:MM:SS",
        dateformat"yyyy-mm-ddTHH:MM:SS",
    )
        parsed = tryparse(DateTime, value, format)
        parsed === nothing || return parsed
    end
    return value
end

function load_collection_metadata_entries(path::AbstractString)::MetadataEntries
    lines = readlines(path)
    isempty(lines) && return MetadataEntries()
    header = strip.(split(first(lines), ','))
    length(header) >= 2 ||
        throw(ArgumentError(
            "Invalid DirectorySource metadata file '$path': expected a path column and " *
            "at least one metadata column",
        ))
    metadata_names = header[2:end]
    entries = MetadataEntries()
    for line in Iterators.drop(lines, 1)
        isempty(strip(line)) && continue
        cells = split(line, ',')
        path_text = strip(first(cells))
        isempty(path_text) && continue
        metadata = Dict{Symbol,Any}()
        for (offset, name) in enumerate(metadata_names)
            index = offset + 1
            index > length(cells) && continue
            value = parse_metadata_value(cells[index])
            value === nothing || (metadata[Symbol(strip(name))] = value)
        end
        entries[Tuple(filter(!isempty, split(path_text, '/')))] = metadata
    end
    return entries
end

function collection_metadata_file_path(source::DirectorySource)::Union{Nothing,String}
    source.metadata_file === nothing && return nothing
    return normpath(joinpath(source.root_path, source.metadata_file))
end

"""Read the metadata file again, and tell whether it changed."""
function load_collection_metadata!(source::DirectorySource)::Bool
    path = collection_metadata_file_path(source)
    present = path !== nothing && isfile(path)
    entries = present ? load_collection_metadata_entries(path::String) : MetadataEntries()
    return lock(source.metadata_lock) do
        changed = source.has_metadata != present ||
            source.collection_metadata_entries != entries
        source.collection_metadata_entries = entries
        source.has_metadata = present
        changed
    end
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

"""The metadata file entries of the folder that `collections` names from the top down."""
function metadata(
    source::DirectorySource,
    collections::AbstractVector{<:DataBrowserAPI.AbstractCollection},
)::Dict
    names = String[id(level) for level in collections]
    values = Dict{Symbol,Any}()
    lock(source.metadata_lock) do
        # A row names the last folders of a path. Rows with fewer names apply first, so that a row
        # with more names gives the value of a key that both give.
        for start in reverse(eachindex(names))
            row = get(source.collection_metadata_entries, Tuple(names[start:end]), nothing)
            row === nothing || merge!(values, row)
        end
    end
    return values
end

function items(
    source::DirectorySource;
    on_progress::Union{Nothing,Function}=nothing,
    on_item::Union{Nothing,Function}=nothing,
    cancel_token::CancellationToken,
)::Vector{SourceFile}
    files = SourceFile[]
    metadata_path = collection_metadata_file_path(source)
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
            elseif isfile(path) && path != metadata_path && !(lowercase(name) in DIRECTORY_SOURCE_SIDECARS)
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
    load_collection_metadata!(source)
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
    # that is not recursive. The metadata file is watched in any case.
    function ignore(path::AbstractString)::Bool
        path == source.metadata_file && return false
        return any(startswith('.'), split(path, '/')) || (!source.recursive && occursin('/', path))
    end
    task = Base.Threads.@spawn begin
        errored = false
        try
            watch_folder(source.root_path, watch_token; ignore) do _
                is_cancellation_requested(watch_token) && return
                metadata_changed = try
                    load_collection_metadata!(source)
                catch error
                    errored = true
                    on_change(SourceError(sprint(showerror, error)))
                    return
                end
                files = items(source; cancel_token=watch_token)
                is_cancellation_requested(watch_token) && return
                current = Dict(id(file) => fingerprint(file) for file in files)
                upserts = SourceFile[
                    file for file in files
                    if !haskey(known, id(file)) ||
                       !isequal(known[id(file)], fingerprint(file))
                ]
                removals = String[file_id for file_id in keys(known) if !haskey(current, file_id)]
                # After an error, report even an empty change, so that the error is cleared.
                isempty(upserts) && isempty(removals) && !metadata_changed && !errored && return
                known = current
                errored = false
                on_change(SourceChanges(upserts, removals; metadata_changed))
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

Unopened directory source with the same root, scan depth, and metadata file. Does not copy the
watcher.
"""
Base.copy(source::DirectorySource) = DirectorySource(
    source.root_path;
    recursive=source.recursive,
    metadata_file=source.metadata_file,
)

function close_source!(source::DirectorySource)::Nothing
    source.watcher_cancel === nothing || cancel(source.watcher_cancel)
    # The task reports its own errors through `on_change`, so waiting for it does not throw.
    source.watcher_task === nothing || wait(source.watcher_task)
    source.watcher_task = nothing
    source.watcher_cancel = nothing
    return nothing
end
