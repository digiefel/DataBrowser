# Render Julia files into the Literate pages that docs/make.jl makes, without building the site.
# Usage: julia --project=docs render.jl OUTDIR path/to/file.jl ...   (paths from the repository root)
using Literate
const ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
out = ARGS[1]
for path in ARGS[2:end]
    Literate.markdown(joinpath(ROOT, path), out;
        name=splitext(basename(path))[1],
        flavor=Literate.CommonMarkFlavor(),
        execute=false,
        credit=false,
        preprocess=source -> "# # `$path`\n#\n" * source,
    )
end
