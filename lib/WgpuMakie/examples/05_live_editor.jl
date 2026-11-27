# Live bi-directional editor + Grafico example with standalone code export.
# Usage:
#   julia --project=lib/WgpuMakie lib/WgpuMakie/examples/05_live_editor.jl
#   julia --project=lib/WgpuMakie lib/WgpuMakie/examples/05_live_editor.jl --save /tmp/05_live_editor.png

using Pkg
const GRAFICO_DIR = normpath(joinpath(@__DIR__, "..", "..", "Grafico"))
if !(GRAFICO_DIR in LOAD_PATH)
    push!(LOAD_PATH, GRAFICO_DIR)
end

using Grafico
using WgpuMakie

function build_example()
    xs = collect(range(0.1, 10.0; length = 60))
    rows = vcat(
        [(x = x, signal = sin(x) + 1.4, series = "alpha", phase = round(x; digits = 2)) for x in xs],
        [(x = x, signal = 0.7 * cos(1.5 * x) + 1.8, series = "beta", phase = round(x; digits = 2)) for x in xs],
    )

    spec = @plot data(rows) * mapping(:x => "Time (s)", :signal => "Signal (V)"; color = :series) begin
        visual(Scatter; markersize = 9)
        visual(Lines; linewidth = 2)
        scales(color = (; categories = ["alpha", "beta"]))
        coord(x = (; scale = identity))
        legend(position = :right)
        inspector(:series; title = "Signal Trace", digits = 4)
    end

    ep = editable(spec)
    fig = Grafico.figure(ep)
    return fig, ep
end

function main(args = ARGS)
    fig, ep = build_example()
    idx = findfirst(==("--save"), args)
    if !isnothing(idx) && idx < length(args)
        out = args[idx + 1]
        mkpath(dirname(out))
        WgpuMakie.save(out, fig)
        println("Saved $out")
        println("\nGenerated standalone Grafico code:\n")
        println(Grafico.to_code(ep; include_imports = true, include_figure = true))
    else
        scr = display(fig; title = "WgpuMakie Live Editor")
        println("Click Editor in the toolbar to edit layers, scales, theme, or copy Grafico code.")
        isinteractive() || wait(scr)
    end
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
