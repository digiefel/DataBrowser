"""
Premade recipes: complete registrations for formats common enough to ship.

Each one is written against `register_item!` and nothing else. A premade recipe must never reach
past the public dialect — if one needs something that is not there, that is a gap in the dialect to
close rather than a private hook to add.

Reading formats is what this package is for, so their parsers are ordinary dependencies and a
premade recipe simply works after `using DataBrowser`. A format heavy enough that projects not
using it should not pay for it belongs behind a package extension instead; that trades the
zero-ceremony story for load time, and only earns it when the dependency is genuinely large and not
already in the graph.
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
item ID. Every other keyword is an ordinary `register_item!` callback and is forwarded untouched,
so a premade recipe is a starting point rather than a different kind of thing:

```julia
register_csv!(project, :sweep;
    extensions=[".csv", ".txt"],
    read_options=(; delim='\\t', comment="#"),
    collection=(data, metadata) -> (measurement = "sweeps", device = metadata[:device]),
    analyze=(data, _metadata) -> Dict(:rows => nrow(data)),
)
```

Detection runs in registration order and the first match wins, so register narrower recipes before
this one when several could claim the same file. `read` has a method for the `SourceFile` items of a
directory source; a source with another type of source item needs a registration with its own
`read` callback.
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
