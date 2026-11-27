# Declarative plot annotations and live fit labels edited through `Grafico.EditablePlot`.
# Usage:
#   julia --project=lib/WgpuMakie lib/WgpuMakie/examples/09_annotations_and_fit_labels.jl
#   julia --project=lib/WgpuMakie lib/WgpuMakie/examples/09_annotations_and_fit_labels.jl --save /tmp/09.png

const GRAFICO_DIR = normpath(joinpath(@__DIR__, "..", "..", "Grafico"))
if !(GRAFICO_DIR in LOAD_PATH)
    push!(LOAD_PATH, GRAFICO_DIR)
end

using Grafico
using WgpuMakie

damped_decay(x; A = 1.0, tau = 1.0, y0 = 0.0) = A * exp(-x / tau) + y0

function build_example()
    xs = collect(range(0.0, 10.0; length = 65))
    ys = [2.4 * exp(-x / 3.2) + 0.35 + 0.06 * sin(2.5 * x) for x in xs]
    df = (t = xs, v = ys)

    p = @plot data(df) * mapping(:t => "Time (ms)", :v => "Voltage (V)") begin
        f = fit(damped_decay, (A = 2.0, tau = 2.5, y0 = 0.2))
        visual(Scatter; color = :steelblue, markersize = 10)
        f * visual(Lines; color = :crimson, linewidth = 2.5)
        annotate(:fit_label, f; x = 0.70, y = 0.94, space = :relative, digits = 3, title = "Exponential Fit")
        annotate(:vspan, "Pulse Window"; xmin = 1.6, xmax = 3.2, y = 2.74, color = (:gold, 0.22), strokecolor = :goldenrod, strokewidth = 1.0)
        annotate(:hline, "Baseline"; y = 0.35, x = 8.4, color = :gray45, linestyle = :dash, linewidth = 1.5)
        annotate(:callout, "Peak t = 0"; x = 0.0, y = 2.75, tx = 0.55, ty = 2.48, color = :navy)
        annotate(:arrow, "Decay"; x = 3.4, y = 1.48, x2 = 5.6, y2 = 0.96, color = :darkgreen, linewidth = 2.0)
        annotate(:text, "Steady tail"; x = 7.8, y = 0.72, color = :gray25)
    end

    ep = editable(p)
    fig = Grafico.figure(ep; figure_kw = (; size = (980, 620)))
    return fig, ep
end

idx = findfirst(==("--save"), ARGS)
fig, ep = build_example()
if isnothing(idx) || idx >= length(ARGS)
    display(fig; title = "WgpuMakie Annotations & Fit Label")
    println("Standalone Grafico code:\n")
    println(Grafico.to_code(ep; include_imports = true, include_figure = true))
    println("\nSwitch to Edit / Text / Arrow / Callout tools in the top bar. Close viewer or press Enter...")
    readline()
else
    out = ARGS[idx + 1]
    mkpath(dirname(out))
    Makie.save(out, fig)
    println("Saved ", out)
    println(Grafico.to_code(ep; include_imports = true, include_figure = true))
end
