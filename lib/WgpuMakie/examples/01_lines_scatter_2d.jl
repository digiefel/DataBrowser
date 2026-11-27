using WgpuMakie

function parse_save_arg(args)
    idx = findfirst(==("--save"), args)
    return isnothing(idx) || idx >= length(args) ? nothing : args[idx + 1]
end

function build_figure()
    xs = range(0, 4π; length = 400)
    fig = Figure(size = (900, 600))
    ax = Axis(fig[1, 1]; xlabel = "Phase (rad)", ylabel = "Amplitude", title = "2D Lines, Segments & Scatter")
    lines!(ax, xs, sin.(xs); color = :royalblue, linewidth = 3, label = "sin(x)")
    lines!(ax, xs, cos.(xs); color = :crimson, linewidth = 2.5, linestyle = :dash, label = "cos(x)")

    sx = range(0, 4π; length = 28)
    scatter!(ax, sx, sin.(sx) .* 0.8; color = collect(sx), colormap = :viridis, markersize = 14, label = "samples")

    segs = Point2f[]
    for x in sx[1:2:end]
        push!(segs, Point2f(x, 0.0f0), Point2f(x, sin(x) * 0.8))
    end
    linesegments!(ax, segs; color = RGBAf(0.2, 0.2, 0.2, 0.5), linewidth = 1.5)
    axislegend(ax)
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
