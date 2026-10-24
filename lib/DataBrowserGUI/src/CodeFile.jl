"""
    CodeFile(path)

Code that a window shows and edits, kept in a file that other editors may change too. `path` is
the file, or `""` while the code has none.

`code.text` is the code in the window, and `code.saved` the code as last read from or written to
the file. [`load!`](@ref) reads the file, [`save!`](@ref) writes the code to it, and
[`edit!`](@ref) replaces one part of the code and leaves the rest as the user wrote it.
[`isunsaved`](@ref) and [`ischanged_on_disk`](@ref) tell whether the window or the file has changes
that the other does not have.
"""
Base.@kwdef mutable struct CodeFile
    path::String = ""
    text::String = ""
    saved::String = ""
    # The modification time of the file when it was last read or written; 0 without a file.
    mtime::Float64 = 0.0
end
CodeFile(path::String) = CodeFile(; path)

"""
    load!(code::CodeFile) -> CodeFile

Read the code from the file. Without a file, the code is empty.
"""
function load!(code::CodeFile)::CodeFile
    exists = !isempty(code.path) && isfile(code.path)
    code.saved = exists ? read(code.path, String) : ""
    code.mtime = exists ? mtime(code.path) : 0.0
    code.text = code.saved
    return code
end

"""
    save!(code::CodeFile) -> CodeFile

Write the code to the file, creating its directory. A failed write leaves the file as it was.
"""
function save!(code::CodeFile)::CodeFile
    isempty(code.path) && error("The code has no file to save to")
    mkpath(dirname(abspath(code.path)))
    temporary = code.path * ".saving"
    write(temporary, code.text)
    mv(temporary, code.path; force=true)
    code.saved = code.text
    code.mtime = mtime(code.path)
    return code
end

"""
    edit!(code::CodeFile, range::UnitRange{Int}, text::String) -> CodeFile

Replace the bytes `range` of the code with `text`. An empty range, such as `5:4`, inserts `text`
before byte 5. The rest of the code stays as it is.
"""
function edit!(code::CodeFile, range::UnitRange{Int}, text::String)::CodeFile
    bytes = codeunits(code.text)
    code.text = String(bytes[1:first(range)-1]) * text * String(bytes[last(range)+1:end])
    return code
end

"""
    isunsaved(code::CodeFile) -> Bool

Whether the code in the window differs from the code as last read from or written to the file.
"""
isunsaved(code::CodeFile)::Bool = code.text != code.saved

"""
    ischanged_on_disk(code::CodeFile) -> Bool

Whether another editor changed the file since it was last read or written.
"""
ischanged_on_disk(code::CodeFile)::Bool = !isempty(code.path) && isfile(code.path) && mtime(code.path) != code.mtime

