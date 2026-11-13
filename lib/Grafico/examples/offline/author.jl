using Grafico, Makie
include("kernels.jl")
using .GraficoPortableKernels: cloud_x, cloud_y

points = [(x = 0.7cos(t) + 0.15cos(3t), y = 0.5sin(t))
          for t in range(0, 2π; length = 81)[1:end-1]]

angle = Observable(0.0)
stretch = Observable(1.0)
source = Observable(points)

# Scientific arrays and interval controls use the same ordinary dependency graph.
trace_time = collect(range(0.0, 1.0; length = 1025))
time = Observable(trace_time)
signal = Observable(@. sin(6π * trace_time) + 0.3 * trace_time + 0.1 * cos(31π * trace_time))
lower = Observable(0.0)
upper = Observable(1.0)
interval = lift(tuple, lower, upper)
area = lift(time, signal, interval) do t, current, bounds
    GraficoPortableKernels.interval_integral(t, current, bounds...)
end

rows = lift(angle, stretch, source) do a, s, points
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
