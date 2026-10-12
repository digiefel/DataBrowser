"""
Tags — catalog of named tags plus per-key assignments stored at `<root>/tags.txt`.

The file has two sections, each introduced by a bracketed header:

    [catalog]
    bad\\tff3030\\t100
    todo\\t30c0ff\\t50

    [assignments]
    RuO2test/A9/VI/D1                                          bad
    /Users/davide/data/RuO2test/A9/VI/D1/3V FE PUND.csv        bad
    RuO2test/A10/VI                                            todo

Assignment rows are `<key>\\t<tag_name>`. Keys are registration collection-path strings
(slash-joined segments, e.g. `RuO2test/A9/VI/D1`), typed collection IDs prefixed with
`@collection/`, or item ids from [`id`](@ref).
The two namespaces never overlap, so no kind prefix is needed. Fields are
tab-separated on write; whitespace-tolerant on read. Lines starting with `#`
are comments. Malformed rows raise `TagsParseError`.

`Tags.load` and `Tags.save` only use `tags.txt`.
"""
module Tags

using ..DataBrowserAnnotations: AnnotationKey, collection_annotation_key

export Tag, Untagged, TagState, load, save,
       tags_path, TAGS_FILENAME

const TAGS_FILENAME = "tags.txt"

tags_path(root::AbstractString) = joinpath(String(root), TAGS_FILENAME)

"""
    Tag(name; color="808080", priority=0)

A label that the user puts on items and collections, for example `Tag("bad")`.

The name identifies the tag. `color` is six hexadecimal digits, and is the colour of tagged rows
in the browser. When several tags apply to one row, the tag with the highest `priority` gives the
colour.
"""
struct Tag
    name::String
    color::NTuple{3,UInt8}
    priority::Int
end

function Tag(name::AbstractString; color::AbstractString="808080", priority::Integer=0)
    (isempty(strip(name)) || occursin(r"[\t\n]", name)) &&
        throw(ArgumentError("a tag name is text on one line without tabs, got \"$(escape_string(name))\""))
    digits = lstrip(color, '#')
    length(digits) == 6 && all(isxdigit, digits) ||
        throw(ArgumentError("a tag colour is six hexadecimal digits, got \"$color\""))
    return Tag(name, ntuple(i -> parse(UInt8, digits[2i-1:2i]; base=16), 3), priority)
end

"""
The condition "does not have this tag", written `!Tag("bad")`.
"""
struct Untagged
    tag::Tag
end

Base.:!(tag::Tag) = Untagged(tag)
Base.:!(condition::Untagged) = condition.tag

Base.show(io::IO, tag::Tag) =
    print(io, "Tag(\"", tag.name, "\"; color=\"", _format_color(tag.color), "\", priority=", tag.priority, ")")

"""
    TagState

Catalog of `Tag`s plus a single `assignments` map.

Keys are [`AnnotationKey`](@ref) values — either collection paths or item ids.
The two namespaces never overlap.

Only explicitly attached tags are stored; a reader applies the tags of a collection to
everything below it.
"""
struct TagState
    catalog::Vector{Tag}
    assignments::Dict{AnnotationKey,Set{String}}
end

TagState() = TagState(Tag[], Dict{AnnotationKey,Set{String}}())

struct TagsParseError <: Exception
    path::String
    line_number::Int
    message::String
end

function Base.showerror(io::IO, err::TagsParseError)
    print(io, "Invalid $(basename(err.path)) at line $(err.line_number): $(err.message)")
end

function _parse_color_hex(path::String, line_number::Int, raw::AbstractString)
    s = strip(raw)
    startswith(s, '#') && (s = s[2:end])
    length(s) == 6 || throw(TagsParseError(path, line_number,
        "expected 6-digit hex color, got '$raw'"))
    r = tryparse(UInt8, s[1:2]; base=16)
    g = tryparse(UInt8, s[3:4]; base=16)
    b = tryparse(UInt8, s[5:6]; base=16)
    (r === nothing || g === nothing || b === nothing) &&
        throw(TagsParseError(path, line_number, "bad hex color '$raw'"))
    return (r, g, b)
end

function _split_row(line::AbstractString)
    if occursin('\t', line)
        return [strip(p) for p in split(line, '\t') if !isempty(strip(p))]
    end
    return [strip(p) for p in split(line) if !isempty(strip(p))]
end

function load(root::AbstractString)::TagState
    path = tags_path(root)

    catalog = Tag[]
    assignments = Dict{AnnotationKey,Set{String}}()

    if isfile(path)
        section = :none
        for (line_number, raw) in enumerate(eachline(path))
            body = strip(raw)
            isempty(body) && continue
            startswith(body, '#') && continue
            if startswith(body, '[') && endswith(body, ']')
                header = strip(body[2:end-1])
                if header == "catalog"
                    section = :catalog
                elseif header == "assignments"
                    section = :assignments
                else
                    throw(TagsParseError(path, line_number, "unknown section '[$header]'"))
                end
                continue
            end

            fields = _split_row(body)
            if section == :catalog
                length(fields) == 3 || throw(TagsParseError(path, line_number,
                    "expected '<name>\\t<color>\\t<priority>'"))
                name = String(fields[1])
                isempty(name) && throw(TagsParseError(path, line_number, "empty tag name"))
                color = _parse_color_hex(path, line_number, fields[2])
                priority = tryparse(Int, fields[3])
                priority === nothing && throw(TagsParseError(path, line_number,
                    "bad priority '$(fields[3])'"))
                push!(catalog, Tag(name, color, priority))
            elseif section == :assignments
                length(fields) == 2 || throw(TagsParseError(path, line_number,
                    "expected '<key>\\t<tag_name>'"))
                key = collection_annotation_key(fields[1])
                tag = String(fields[2])
                (isempty(key) || isempty(tag)) &&
                    throw(TagsParseError(path, line_number, "empty key or tag name"))
                set = get!(() -> Set{String}(), assignments, key)
                push!(set, tag)
            else
                throw(TagsParseError(path, line_number,
                    "row outside of any section; expected '[catalog]' or '[assignments]' header first"))
            end
        end
    end

    return TagState(catalog, assignments)
end

function _format_color(color::NTuple{3,UInt8})
    return string(
        lpad(string(color[1]; base=16), 2, '0'),
        lpad(string(color[2]; base=16), 2, '0'),
        lpad(string(color[3]; base=16), 2, '0'),
    )
end

function save(root::AbstractString, state::TagState)
    path = tags_path(root)
    if isempty(state.catalog) && isempty(state.assignments)
        rm(path; force=true)
        return
    end

    open(path, "w") do io
        println(io, "[catalog]")
        for tag in state.catalog
            println(io, tag.name, '\t', _format_color(tag.color), '\t', tag.priority)
        end

        if !isempty(state.assignments)
            println(io)
            println(io, "[assignments]")
            for key in sort!(collect(keys(state.assignments)))
                tags = sort!(collect(state.assignments[key]))
                for tag in tags
                    println(io, key, '\t', tag)
                end
            end
        end
    end
end

end # module
