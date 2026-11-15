using Grafico, WGLMakie, CairoMakie

phase = Observable(0.0)
shown = Observable(1)
window = Observable((0.0, 1.0))
colour = Observable(RGBAf(0.12, 0.47, 0.71, 1))
t = collect(range(0, 1; length = 60))
rows = lift(phase, shown) do phase, shown
    (x = t[1:shown], y = sin.(6π .* t[1:shown] .+ phase))
end
curve = data(rows) * mapping(:x, :y) * visual(Lines; color = colour) +
    coord(x = (limits = window,), y = (limits = (-1.2, 1.2),))
bins = data(rows) * mapping(:y) * Grafico.histogram(bins = range(-1.2, 1.2; length = 13))
fig = figure(curve | bins; figure_kw = (size = (1000, 800),))

# These additions are ordinary Makie, outside Grafico's GoG compiler.
ax3 = Axis3(fig[2, 1]; limits = (-1, 1, -1, 1, -0.5, 1.5))
vertices = lift(phase) do phase
    Point3f[(-0.8, -0.6, 0), (0.8, -0.6, 0), (0, 0.7, 0.5 + 0.4sin(phase))]
end
mesh!(ax3, vertices, [Makie.GeometryBasics.TriangleFace(1, 2, 3)]; color = colour)
ax2 = Axis(fig[2, 2]; limits = (0, 1, 0, 1))
image = lift(p -> Float32[sin(0.2i + p) * cos(0.2j) for i in 1:30, j in 1:20], phase)
heatmap!(ax2, (0, 1), (0, 1), image)
caption = lift(p -> p < 1 ? "before α" : "after β", phase)
text!(ax2, (0.5, 0.9); text = caption, align = (:center, :center))

story = Grafico.plan(sequence(
    to(shown => length(t); duration = 1.0, ease = identity),
    together(to(phase => 2.5), to(colour => RGBAf(0.84, 0.15, 0.16, 1)),
             to(window => (0.2, 0.55))),
    hold(0.2),
))
output = joinpath(@__DIR__, "output")
mkpath(output)
record(fig, joinpath(output, "native.html"), story;
       still = joinpath(output, "final.svg"))
