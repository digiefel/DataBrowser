let
    repo_root = normpath(joinpath(@__DIR__, "..", "..", ".."))
    grafico_dir = joinpath(repo_root, "lib", "Grafico")
    grafico_dir in LOAD_PATH || push!(LOAD_PATH, grafico_dir)
end

using WgpuMakie
using Grafico

function parse_save_arg(args)
    idx = findfirst(==("--save"), args)
    return isnothing(idx) || idx >= length(args) ? nothing : args[idx + 1]
end

function build_figure()
    rows = [
        (x = x, y = sin(x) + offset, series = label)
        for (label, offset) in (("alpha", 0.0), ("beta", 1.2))
        for x in range(0.0, 2π; length = 40)
    ]
    spec = @plot data(rows) * mapping(:x, :y; color = :series) begin
        visual(Lines; linewidth = 2.5)
        visual(Scatter; markersize = 8)
    end
    return Grafico.figure(spec)
end

save_path = parse_save_arg(ARGS)
fig = build_figure()
if isnothing(save_path)
    scr = display(fig)
    isinteractive() || wait(scr)
else
    mkpath(dirname(save_path))
    Makie.save(save_path, fig)
    println("Saved ", save_path)
end
