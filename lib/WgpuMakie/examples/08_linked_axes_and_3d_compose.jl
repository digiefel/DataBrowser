using WgpuMakie

function parse_save_arg(args)
    idx = findfirst(==("--save"), args)
    return isnothing(idx) || idx >= length(args) ? nothing : args[idx + 1]
end

"""
Build a multi-panel composed figure with linked 2D linear/log axes, a colorbar, and a 3D surface plot.
"""
function build_figure()
    xs = collect(Float32, range(0.1f0, 12.0f0; length = 240))
    signal = @. exp(-0.18f0 * xs) * (1.2f0 + sin(2.5f0 * xs)) + 0.05f0

    fig = Figure(size = (1240, 680))

    ax_top = Axis(
        fig[1, 1];
        ylabel = "Linear Amplitude",
        title = "Linked Linear + Log10 2D Axes",
    )
    lines!(ax_top, xs, signal; color = :navy, linewidth = 2.5)
    scatter!(ax_top, xs[1:12:end], signal[1:12:end]; color = signal[1:12:end], colormap = :plasma, markersize = 10)

    ax_bot = Axis(
        fig[2, 1];
        xlabel = "Distance (mm)",
        ylabel = "Log10 Amplitude",
        yscale = log10,
    )
    linkxaxes!(ax_top, ax_bot)
    lines!(ax_bot, xs, signal; color = :teal, linewidth = 2.5)

    Colorbar(fig[1:2, 2]; colormap = :plasma, limits = (minimum(signal), maximum(signal)), label = "Intensity")

    ax3 = Axis3(
        fig[1:2, 3];
        xlabel = "X",
        ylabel = "Y",
        zlabel = "Height",
        title = "Composed 3D Surface & Peaks",
    )
    gx = collect(Float32, range(-3.0f0, 3.0f0; length = 44))
    gy = collect(Float32, range(-3.0f0, 3.0f0; length = 44))
    gz = [cos(sqrt(x^2 + y^2) * 1.6f0) * exp(-0.15f0 * (x^2 + y^2)) for x in gx, y in gy]
    surface!(ax3, gx, gy, gz; colormap = :viridis, shading = true)

    ring_theta = collect(Float32, range(0.0f0, 2.0f0 * Float32(pi); length = 32))
    rx = 1.9f0 .* cos.(ring_theta)
    ry = 1.9f0 .* sin.(ring_theta)
    rz = fill(0.6f0, length(ring_theta))
    scatter!(ax3, rx, ry, rz; color = :gold, markersize = 11)

    colgap!(fig.layout, 2, 48)
    colsize!(fig.layout, 1, Relative(0.42))

    return fig
end

save_path = parse_save_arg(ARGS)
fig = build_figure()
if isnothing(save_path)
    display(fig)
    println("Close the viewer window or press Enter to exit...")
    readline()
else
    mkpath(dirname(save_path))
    Makie.save(save_path, fig)
    println("Saved ", save_path)
end
