"""
Premade recipes: complete registrations for common formats.

Each one calls only `register_item!`, so a project can do the same with callbacks of its own. When
a premade recipe needs something that `register_item!` does not give, add it to `register_item!`.

The parsers of these formats, such as CSV.jl, are dependencies of this package, so a premade recipe
works after `using DataBrowser`. A format whose parser is large and not yet a dependency belongs in
a package extension instead, so that projects that do not use the format do not load its parser.
"""

"""Whether one source item's name carries any of the given lowercase extensions."""
function _has_extension(source_item::AbstractDataSourceItem, extensions::Vector{String})::Bool
    name = lowercase(label(source_item))
    return any(extension -> endswith(name, extension), extensions)
end

"""Parse the file of one source item into a `DataFrame`."""
_read_delimited(file::SourceFile, options::NamedTuple)::DataFrame =
    CSV.read(file.filepath, DataFrame; options...)

"""
    register_csv!(project, [kind]; extensions, read_options, label, callbacks...) -> project

Register delimited text files as items, one item per file.

`detect` matches by file extension (case-insensitively, `[".csv"]` by default), `read` parses
with CSV.jl into a `DataFrame`, and the default `label` is the filename, including its extension.
Supply a `label=(data, metadata) -> ...` callback to customize it, or `label=nothing` to use the
item id. Every other keyword goes to `register_item!` as it is, so the call below registers
`:sweep` items as `register_item!` would, with these defaults:

```julia
register_csv!(project, :sweep;
    extensions=[".csv", ".txt"],
    read_options=(; delim='\\t', comment="#"),
    collection=(data, metadata) -> (measurement = "sweeps", device = metadata[:device]),
    analyze=(data, _metadata) -> Dict(:rows => nrow(data)),
)
```

Detection runs in registration order and the first match wins, so register narrower recipes before
this one when several could claim the same file. The `read` callback takes the `SourceFile`s of a
`DirectorySource`. For a source with another type of source item, call `register_item!` with a
`read` callback of your own.
"""
function register_csv!(
    project::Project,
    kind::Symbol;
    extensions::AbstractVector{<:AbstractString}=[".csv"],
    read_options::NamedTuple=NamedTuple(),
    label=(_data, metadata) -> metadata[:filename],
    kwargs...,
)::Project
    normalized = String[lowercase(extension) for extension in extensions]
    return register_item!(
        project,
        kind;
        detect=source_item -> _has_extension(source_item, normalized),
        read=source_item -> _read_delimited(source_item, read_options),
        label=label,
        kwargs...,
    )
end

register_csv!(project::Project; kwargs...)::Project = register_csv!(project, :csv; kwargs...)
