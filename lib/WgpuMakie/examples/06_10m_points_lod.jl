# 10,000,000-point curve with single-sample spikes preserved by M4 decimation.

using WgpuMakie

n = 10_000_000
xs = collect(Float32, range(0.0f0, 100.0f0; length = n))
ys = @. sin(xs * 0.25f0) + 0.35f0 * cos(xs * 1.7f0)

# Inject sharp single-sample spikes that stride subsampling would miss.
ys[1_250_000] = 8.0f0
ys[3_750_000] = -8.0f0
ys[6_250_000] = 8.0f0
ys[8_750_000] = -8.0f0

fig = Figure(size = (1000, 600))
ax = Axis(
    fig[1, 1];
    xlabel = "Time (s)",
    ylabel = "Signal (a.u.)",
    title = "10,000,000 Points (M4 Spike-Preserving LOD)",
)
lines!(ax, xs, ys; color = :royalblue, linewidth = 1.5, label = "10M samples")
ylims!(ax, -9.0, 9.0)
axislegend(ax)

screen = display(fig)
isinteractive() || wait(screen)
