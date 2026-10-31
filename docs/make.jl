# Build the documentation: the home, architecture and API pages, and one page per Julia file, made
# with Literate. Run `julia --project=docs docs/make.jl`; the site appears in `docs/build`.
using Documenter
using DocumenterMermaid
using Literate

const ROOT = dirname(@__DIR__)
# The API page shows the docstrings of the packages, which the bench environment loads.
pushfirst!(LOAD_PATH, joinpath(ROOT, "bench"))
import DataBrowserAPI, DataBrowserSources, DataBrowserRecipes, DataBrowserCore, DataBrowserPlots,
    DataBrowserGUI
const GENERATED = joinpath(@__DIR__, "generated")
# The folders whose Julia files become pages, in the order of the sidebar.
const FOLDERS = ["src", "ext", "lib", "scripts", "test", "examples"]
# The folders whose subfolders each get their own section of the sidebar.
const GROUPED_FOLDERS = ["lib", "examples"]

rm(GENERATED; recursive=true, force=true)
mkpath(GENERATED)
cp(joinpath(@__DIR__, "ARCHITECTURE.md"), joinpath(GENERATED, "ARCHITECTURE.md"))
cp(joinpath(@__DIR__, "api.md"), joinpath(GENERATED, "api.md"))
cp(joinpath(@__DIR__, "index.md"), joinpath(GENERATED, "index.md"))

# The Julia files that git tracks and that exist, and the new ones that it does not ignore.
files = readlines(Cmd(`git ls-files --cached --others --exclude-standard -- '*.jl'`; dir=ROOT))
filter!(path -> first(splitpath(path)) in FOLDERS && isfile(joinpath(ROOT, path)), files)
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
    sitename="DataBrowser",
    format=Documenter.HTML(prettyurls=false),
    doctest=false,
    checkdocs=:none,
    # ARCHITECTURE.md links to roadmap.md, which is not a page of this site.
    # TODO: an error again once the architecture lives in the code.
    # TODO: an error again once `AbstractDataItem` has a docstring and the public docstrings link
    # only to public names.
    warnonly=[:cross_references, :docs_block],
    pages=["Home" => "index.md", "Architecture" => "ARCHITECTURE.md", "API" => "api.md", sections...],
)
