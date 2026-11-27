# Multi-panel figure with a zoom inset, dockable legend, colorbar, and brush selection callback.
# Select Edit in the toolbar to drag subplot dividers, the legend, the colorbar, or inset corners;
# select Brush to drag a selection rectangle over points.

using WgpuMakie

xs = collect(Float32, range(0.0f0, 12.0f0; length = 260))
y1 = @. exp(-0.18f0 * xs) * cos(2.8f0 * xs) + 0.12f0 * sin(9.0f0 * xs)
y2 = @. abs.(y1) .+ 0.04f0

fig = Figure(size = (1180, 660))

ax1 = Axis(fig[1, 1]; xlabel = "Time (s)", ylabel = "Signal (V)", title = "Waveform + Zoom Inset")
lines!(ax1, xs, y1; color = :navy, linewidth = 2.0, label = "signal")
scatter!(ax1, xs[1:8:end], y1[1:8:end]; color = y2[1:8:end], colormap = :plasma, markersize = 10, label = "samples")

# Region outline matching the zoom inset below.
poly!(ax1, Rect2f(0.4f0, 0.35f0, 2.2f0, 0.72f0); color = (:transparent, 0.0), strokecolor = :crimson, strokewidth = 1.5, inspectable = false)

inset_ax = Axis(
    fig[1, 1];
    width = Relative(0.36),
    height = Relative(0.34),
    halign = 0.94,
    valign = 0.92,
    tellwidth = false,
    tellheight = false,
    backgroundcolor = :white,
    title = "Zoom [0.4..2.6]",
)
lines!(inset_ax, xs, y1; color = :navy, linewidth = 2.0)
scatter!(inset_ax, xs[1:4:end], y1[1:4:end]; color = :crimson, markersize = 7)
xlims!(inset_ax, 0.4, 2.6)
ylims!(inset_ax, 0.35, 1.07)

ax2 = Axis(fig[1, 2]; xlabel = "Sample Value", ylabel = "|Amplitude|", title = "Magnitude Spectrum View")
scatter!(ax2, xs, y2; color = y2, colormap = :plasma, markersize = 8)
lines!(ax2, xs, y2; color = (:teal, 0.55), linewidth = 1.5)

Legend(fig[1, 3], ax1)
Colorbar(fig[2, 1:2]; vertical = false, colormap = :plasma, limits = (minimum(y2), maximum(y2)), label = "Magnitude")
colgap!(fig.layout, 1, 22)
rowgap!(fig.layout, 1, 22)

screen = display(fig; title = "WgpuMakie Layout, Insets & Brushing")
on(screen.brush_selection) do sel
    isnothing(sel) && return
    count = sum(length(idxs) for (_, idxs) in sel.plots)
    println("Brushed ", count, " vertices inside ", sel.rect)
end

isinteractive() || wait(screen)
