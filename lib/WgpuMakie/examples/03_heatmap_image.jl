using WgpuMakie

function parse_save_arg(args)
    idx = findfirst(==("--save"), args)
    return isnothing(idx) || idx >= length(args) ? nothing : args[idx + 1]
end

function build_figure()
    fig = Figure(size = (960, 480))
    ax1 = Axis(fig[1, 1]; title = "Heatmap", xlabel = "x", ylabel = "y")
    xs = range(-2, 2; length = 80)
    ys = range(-2, 2; length = 60)
    mat = [exp(-(x^2 + y^2)) * cos(3x) for x in xs, y in ys]
    hm = heatmap!(ax1, xs, ys, mat; colormap = :inferno)
    Colorbar(fig[1, 2], hm)

    ax2 = Axis(fig[1, 3]; title = "RGBA Image", aspect = DataAspect())
    img = [RGBAf(i / 64, j / 64, 0.5f0, 1.0f0) for i in 1:64, j in 1:64]
    image!(ax2, img)
    return fig
end

save_path = parse_save_arg(ARGS)
if isnothing(save_path)
    WgpuMakie.activate!(; headless = false, visible = true, show_editor = true)
    fig = build_figure()
    display(fig)
    println("Close the viewer window or press Enter to exit...")
    readline()
else
    WgpuMakie.activate!(; headless = true, visible = false, show_editor = false)
    fig = build_figure()
    mkpath(dirname(save_path))
    Makie.save(save_path, fig)
    println("Saved ", save_path)
end
