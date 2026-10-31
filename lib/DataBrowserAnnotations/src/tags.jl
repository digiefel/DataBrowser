"""
Tags: named labels that the user puts on items and collections. [`load`](@ref) and
[`save`](@ref) keep them in the file `tags.txt` of a folder. The file has two sections, each after
a header in brackets. `\\t` stands for a tab:

    # Lines that start with `#` are comments.
    [catalog]
    bad\\tff3030\\t100
    todo\\t30c0ff\\t50

    [assignments]
    A9/VI/D1\\tbad
    A10/VI\\ttodo
    A9/VI/D1/3V FE PUND.csv\\tbad

A catalog row is `<name>\\t<color>\\t<priority>`: it defines one [`Tag`](@ref). An assignment row
is `<key>\\t<name>`: it puts the tag `name` on `key`. A key is the id of an item, or the path of a
collection: the labels of the collections from the top down, joined with `/`.

[`save`](@ref) separates fields with tabs. [`load`](@ref) also accepts spaces between fields, when
a row has no tab. A row that does not follow this format raises a `TagsParseError`.
"""
module Tags

export Tag, Untagged, TagState, load, save, tags_path, TAGS_FILENAME

const TAGS_FILENAME = "tags.txt"

tags_path(root::AbstractString) = joinpath(String(root), TAGS_FILENAME)

"""
    Tag(name; color="808080", priority=0)

A label that the user puts on items and collections, for example `Tag("bad")`.

The name identifies the tag. `color` is six hexadecimal digits, and is the color of tagged rows
in the browser. When several tags apply to one row, the tag with the highest `priority` gives the
color.
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
        throw(ArgumentError("a tag color is six hexadecimal digits, got \"$color\""))
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

The content of `tags.txt`: the `catalog` of defined tags, and the `assignments` from each key to
the names of the tags put on it.

Only the tags put on a key itself are stored. A reader applies the tags of a collection to
everything below it.
"""
struct TagState
    catalog::Vector{Tag}
    assignments::Dict{String,Set{String}}
end

TagState() = TagState(Tag[], Dict{String,Set{String}}())

struct TagsParseError <: Exception
    path::String
    line_number::Int
    message::String
end

function Base.showerror(io::IO, err::TagsParseError)
    print(io, "Invalid $(basename(err.path)) at line $(err.line_number): $(err.message)")
end

function _split_row(line::AbstractString)
    if occursin('\t', line)
        return [strip(p) for p in split(line, '\t') if !isempty(strip(p))]
    end
    return [strip(p) for p in split(line) if !isempty(strip(p))]
end

"""
    load(root) -> TagState

Read `tags.txt` in the folder `root`. A folder without the file has no tags.
"""
function load(root::AbstractString)::TagState
    path = tags_path(root)
    state = TagState()
    isfile(path) || return state
    section = :none
    for (line_number, raw) in enumerate(eachline(path))
        body = strip(raw)
        (isempty(body) || startswith(body, '#')) && continue
        if startswith(body, '[') && endswith(body, ']')
            header = strip(body[2:end-1])
            header in ("catalog", "assignments") ||
                throw(TagsParseError(path, line_number, "unknown section '[$header]'"))
            section = Symbol(header)
            continue
        end
        fields = _split_row(body)
        if section == :catalog
            length(fields) == 3 || throw(TagsParseError(path, line_number,
                "expected '<name>\\t<color>\\t<priority>'"))
            priority = tryparse(Int, fields[3])
            priority === nothing && throw(TagsParseError(path, line_number,
                "bad priority '$(fields[3])'"))
            tag = try
                Tag(fields[1]; color=fields[2], priority)
            catch error
                error isa ArgumentError || rethrow()
                throw(TagsParseError(path, line_number, error.msg))
            end
            push!(state.catalog, tag)
        elseif section == :assignments
            length(fields) == 2 || throw(TagsParseError(path, line_number,
                "expected '<key>\\t<tag_name>'"))
            push!(get!(() -> Set{String}(), state.assignments, String(fields[1])), String(fields[2]))
        else
            throw(TagsParseError(path, line_number,
                "row outside of any section; expected '[catalog]' or '[assignments]' header first"))
        end
    end
    return state
end

function _format_color(color::NTuple{3,UInt8})
    return string(
        lpad(string(color[1]; base=16), 2, '0'),
        lpad(string(color[2]; base=16), 2, '0'),
        lpad(string(color[3]; base=16), 2, '0'),
    )
end

"""
    save(root, state::TagState)

Write `state` to `tags.txt` in the folder `root`. Without tags, the file is removed.
"""
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
