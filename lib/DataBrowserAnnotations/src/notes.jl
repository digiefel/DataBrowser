"""
Notes: text that the user writes about items and collections. [`read_section`](@ref) and
[`write_section!`](@ref) keep them in the file `notes.txt` of a folder.

Each note is a section: a key in brackets on its own line, then the text between two lines of
three backticks:

    [ChipB]
    ```
    Oxygen flow: 5%
    ```
    [ChipB/SiteVI]
    ```
    dust particle visible
    [observed in second pass]
    ```

A key has the same form as in `tags.txt`. Only the backtick lines end a note, so a note can
contain lines in brackets. A line in brackets starts a section only when the next line that is not
blank is a line of three backticks. A note keeps its spaces and line breaks, except a line break at
its end.
"""
module Notes

# TODO: nothing reads notes yet. Roadmap 0.4.0 connects them to items and collections.

export read_section, merged_view, write_section!, notes_path,
       NOTES_FILENAME, NotesParseError

const NOTES_FILENAME = "notes.txt"
const FENCE = "```"

notes_path(root::AbstractString) = joinpath(String(root), NOTES_FILENAME)

struct NotesParseError <: Exception
    path::String
    line_number::Int
    message::String
end

function Base.showerror(io::IO, err::NotesParseError)
    print(io, "Invalid $(basename(err.path)) at line $(err.line_number): $(err.message)")
end

function _try_header(line::AbstractString)
    s = strip(line)
    (length(s) >= 2 && first(s) == '[' && last(s) == ']') || return nothing
    inner = strip(s[2:end-1])
    isempty(inner) && return nothing
    return String(inner)
end

function _read_all_sections(path::AbstractString)
    sections = Vector{Tuple{String,String}}()
    isfile(path) || return sections
    lines = readlines(path; keep=false)
    n = length(lines)
    i = 1
    while i <= n
        header = _try_header(lines[i])
        if header === nothing
            stripped = strip(lines[i])
            if !isempty(stripped)
                throw(NotesParseError(path, i,
                    "unexpected content outside of any section"))
            end
            i += 1
            continue
        end

        j = i + 1
        while j <= n && isempty(strip(lines[j]))
            j += 1
        end
        if j > n || strip(lines[j]) != FENCE
            throw(NotesParseError(path, i,
                "expected opening ``` fence after [$header]"))
        end

        body_lines = String[]
        k = j + 1
        closed = false
        while k <= n
            if strip(lines[k]) == FENCE
                closed = true
                break
            end
            push!(body_lines, lines[k])
            k += 1
        end
        closed || throw(NotesParseError(path, j,
            "unterminated fence for section [$header]"))

        body = join(body_lines, '\n')
        push!(sections, (header, body))
        i = k + 1
    end
    return sections
end

"""
    read_section(root, key) -> String

The note of `key` in `notes.txt` in the folder `root`, or `""` when `key` has no note.
"""
function read_section(root::AbstractString, key::AbstractString)::String
    sections = _read_all_sections(notes_path(root))
    for (section_key, body) in sections
        section_key == key && return body
    end
    return ""
end

"""
    merged_view(root, key, ancestor_keys) -> Vector{NamedTuple}

The notes of `ancestor_keys` in the given order, then the note of `key`. Each entry is
`(path, body, editable)`. A key in `ancestor_keys` without a note has no entry, and `key` has an
entry with an empty `body`. Only the entry of `key` is `editable`.
"""
function merged_view(root::AbstractString, key::AbstractString, ancestor_keys)
    sections = _read_all_sections(notes_path(root))
    by_path = Dict{String,String}()
    for (section_key, body) in sections
        by_path[section_key] = body
    end

    out = NamedTuple{(:path, :body, :editable),Tuple{String,String,Bool}}[]
    for ancestor in ancestor_keys
        ancestor_key = String(ancestor)
        haskey(by_path, ancestor_key) || continue
        push!(out, (path=ancestor_key, body=by_path[ancestor_key], editable=false))
    end
    own_key = String(key)
    own_body = get(by_path, own_key, "")
    push!(out, (path=own_key, body=own_body, editable=true))
    return out
end

"""
    write_section!(root, key, body)

Write `body` as the note of `key` in `notes.txt` in the folder `root`. The note takes the place of
the note that `key` had, or else comes after the other notes.
"""
function write_section!(root::AbstractString, key::AbstractString, body::AbstractString)
    file = notes_path(root)
    sections = _read_all_sections(file)
    index = findfirst(section -> first(section) == key, sections)
    note = (String(key), String(body))
    index === nothing ? push!(sections, note) : (sections[index] = note)

    open(file, "w") do io
        for (i, (section_key, sect_body)) in enumerate(sections)
            i > 1 && println(io)
            println(io, '[', section_key, ']')
            println(io, FENCE)
            if !isempty(sect_body)
                print(io, sect_body)
                endswith(sect_body, '\n') || println(io)
            end
            println(io, FENCE)
        end
    end
end

end # module
