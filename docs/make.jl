# Build the source documentation: one page per Julia file, made with Literate, and the architecture
# page. Run `julia --project=docs docs/make.jl`; the site appears in `docs/build`.
using Documenter
using DocumenterMermaid
using Literate

const ROOT = dirname(@__DIR__)
const GENERATED = joinpath(@__DIR__, "generated")
# The folders whose Julia files become pages, in the order of the sidebar.
const FOLDERS = ["src", "ext", "lib", "scripts", "test", "examples"]
# The folders whose subfolders each get their own section of the sidebar.
const GROUPED_FOLDERS = ["lib", "examples"]

rm(GENERATED; recursive=true, force=true)
mkpath(GENERATED)
cp(joinpath(@__DIR__, "ARCHITECTURE.md"), joinpath(GENERATED, "ARCHITECTURE.md"))
write(joinpath(GENERATED, "index.md"), """
    # DataBrowser source

    Each page shows one Julia file of the repository: its comments as text, and its code.
    [Architecture](ARCHITECTURE.md) describes how the packages work together.
    """)

# The Julia files that git tracks, and the new ones that it does not ignore.
files = readlines(Cmd(`git ls-files --cached --others --exclude-standard -- '*.jl'`; dir=ROOT))
filter!(path -> first(splitpath(path)) in FOLDERS, files)
sort!(files; by=path -> (findfirst(==(first(splitpath(path))), FOLDERS), path))

sections = Pair{String,Vector{Pair{String,String}}}[]
for path in files
    page = joinpath("code", splitext(path)[1] * ".md")
    Literate.markdown(joinpath(ROOT, path), dirname(joinpath(GENERATED, page));
        name=splitext(basename(path))[1],
        flavor=Literate.CommonMarkFlavor(),
        execute=false,
        credit=false,
        preprocess=source -> "# # `$path`\n#\n" * source,
    )
    # A section is named after the first folder of the file, or the first two in a grouped folder.
    # The names are code, so that the `_` of a file name does not turn into emphasis.
    parts = splitpath(path)
    depth = first(parts) in GROUPED_FOLDERS ? 2 : 1
    section = "`$(join(parts[1:depth], "/"))`"
    (isempty(sections) || last(sections).first != section) && push!(sections, section => [])
    push!(last(sections).second, "`$(join(parts[depth+1:end], "/"))`" => page)
end

makedocs(
    root=@__DIR__,
    source="generated",
    build="build",
    clean=true,
    sitename="DataBrowser source",
    format=Documenter.HTML(prettyurls=false),
    doctest=false,
    checkdocs=:none,
    # ARCHITECTURE.md links to roadmap.md, which is not a page of this site.
    # TODO: an error again once the architecture lives in the code.
    warnonly=[:cross_references],
    pages=["Source" => "index.md", "Architecture" => "ARCHITECTURE.md", sections...],
)
