using Grafico, Makie
include("kernels.jl")
using .GraficoPortableKernels: cloud_x, cloud_y

points = [(x = 0.7cos(t) + 0.15cos(3t), y = 0.5sin(t))
          for t in range(0, 2π; length = 81)[1:end-1]]

angle = Observable(0.0)
stretch = Observable(1.0)

rows = lift(angle, stretch) do a, s
    (; x = [cloud_x(a, s, p.x, p.y) for p in points],
       y = [cloud_y(a, s, p.x, p.y) for p in points])
end
cloud = data(rows) * mapping(:x, :y) * visual(Scatter; color = Cycled(1)) +
        coord(x = (limits = (-2, 2),), y = (limits = (-2, 2),))

motion = sequence(
    together(to(angle => π / 2; duration = 2), to(stretch => 1.5; duration = 3)),
    along(angle, GraficoPortableKernels.swing; duration = 4),
    to(angle => 0.2, stretch => 0.8; duration = 2),
)
playback = Grafico.plan(motion)
