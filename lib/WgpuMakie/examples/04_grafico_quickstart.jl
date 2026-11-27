using WgpuMakie
using Grafico

rows = [
    (x = x, y = sin(x) + offset, series = label)
    for (label, offset) in (("alpha", 0.0), ("beta", 1.2))
    for x in range(0.0, 2π; length = 40)
]

spec = @plot data(rows) * mapping(:x, :y; color = :series) begin
    visual(Lines; linewidth = 2.5)
    visual(Scatter; markersize = 8)
end

fig = Grafico.figure(spec)

screen = display(fig)
isinteractive() || wait(screen)
