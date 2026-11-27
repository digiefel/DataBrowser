# Live bi-directional editor with Grafico.EditablePlot.
# Open the editor panel in the toolbar to edit layers, scales, theme, or copy Grafico code.

using Grafico
using WgpuMakie

xs = collect(range(0.1, 10.0; length = 60))
rows = vcat(
    [(x = x, signal = sin(x) + 1.4, series = "alpha", phase = round(mod(x, 2pi); digits = 3)) for x in xs],
    [(x = x, signal = 0.7 * cos(1.5 * x) + 1.8, series = "beta", phase = round(mod(1.5 * x, 2pi); digits = 3)) for x in xs],
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

screen = display(fig; title = "WgpuMakie Live Editor")
isinteractive() || wait(screen)
