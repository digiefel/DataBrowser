using WgpuMakie

function parse_save_arg(args)
    idx = findfirst(==("--save"), args)
    return isnothing(idx) || idx >= length(args) ? nothing : args[idx + 1]
end

"""
Build a 10,000,000-point monotonic-X line figure with injected +8 and -8 spikes.
"""
function build_figure()
    n = 10_000_000
    xs = collect(Float32, range(0.0f0, 100.0f0; length = n))
    ys = @. sin(xs * 0.25f0) + 0.35f0 * cos(xs * 1.7f0)
    # Inject sharp single-sample spikes that naive stride subsampling drops.
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
    return fig
end

save_path = parse_save_arg(ARGS)
if isnothing(save_path)
    t0 = time_ns()
    fig = build_figure()
    scr = display(fig)
    dt_ms = (time_ns() - t0) / 1.0e6
    println("Displayed 10M points in ", round(dt_ms; digits = 1), " ms.")
    isinteractive() || wait(scr)
else
    t_build = @elapsed fig = build_figure()
    mkpath(dirname(save_path))
    t_save = @elapsed Makie.save(save_path, fig)
    println("10M LOD example: build=", round(t_build; digits = 2), "s save=", round(t_save; digits = 2), "s -> ", save_path)
end
