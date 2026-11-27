using WgpuMakie

function parse_flag_arg(args, flag::String, default)
    idx = findfirst(==(flag), args)
    return isnothing(idx) || idx >= length(args) ? default : args[idx + 1]
end

"""
Build a 2-channel live Observable waveform and peak marker figure.
"""
function build_streaming_figure()
    n = 2048
    xs = collect(Float32, range(0.0f0, 4.0f0 * Float32(pi); length = n))
    ch1 = Observable(Point2f.(xs, sin.(xs)))
    ch2 = Observable(Point2f.(xs, 0.5f0 .* cos.(2.0f0 .* xs) .- 1.6f0))
    peaks = Observable([Point2f(xs[argmax(sin.(xs))], 1.0f0)])

    fig = Figure(size = (1000, 620))
    ax = Axis(
        fig[1, 1];
        xlabel = "Phase (rad)",
        ylabel = "Voltage (V)",
        title = "Live 2-Channel Observable Streaming + Peak Markers",
    )
    lines!(ax, ch1; color = :dodgerblue, linewidth = 2.5, label = "Channel A")
    lines!(ax, ch2; color = :darkorange, linewidth = 2.0, label = "Channel B")
    scatter!(ax, peaks; color = :crimson, markersize = 14, label = "Peak A")
    xlims!(ax, 0.0, 4.0 * pi)
    ylims!(ax, -2.5, 1.5)
    axislegend(ax)

    function step_frame!(k::Int)
        phase = Float32(k) * 0.14f0
        v1 = ch1.val
        v2 = ch2.val
        best_i = 1
        best_y = -Inf32
        @inbounds for i in eachindex(xs)
            x = xs[i]
            y1 = sin(x + phase) * (0.85f0 + 0.15f0 * cos(0.3f0 * x - phase))
            y2 = 0.55f0 * cos(2.0f0 * x - 1.5f0 * phase) - 1.5f0
            v1[i] = Point2f(x, y1)
            v2[i] = Point2f(x, y2)
            if y1 > best_y
                best_y = y1
                best_i = i
            end
        end
        peaks[][1] = Point2f(xs[best_i], best_y)
        notify(ch1)
        notify(ch2)
        notify(peaks)
    end

    return fig, step_frame!
end

save_path = parse_flag_arg(ARGS, "--save", nothing)
n_frames = parse(Int, string(parse_flag_arg(ARGS, "--frames", "30")))

if isnothing(save_path)
    fig, step_frame! = build_streaming_figure()
    display(fig)
    t0 = time_ns()
    for k in 1:n_frames
        step_frame!(k)
        sleep(1.0 / 60.0)
    end
    dt_s = (time_ns() - t0) / 1.0e9
    println("Streamed ", n_frames, " frames in ", round(dt_s; digits = 2), "s (", round(n_frames / dt_s; digits = 1), " Hz)")
    println("Close the viewer window or press Enter to exit...")
    readline()
else
    fig, step_frame! = build_streaming_figure()
    # Warm up first frame, then time consecutive Observable updates + colorbuffer readbacks.
    Makie.colorbuffer(fig; update = true)
    t0 = time_ns()
    for k in 1:n_frames
        step_frame!(k)
        Makie.colorbuffer(fig; update = true)
    end
    dt_ms = (time_ns() - t0) / 1.0e6
    ms_per_frame = dt_ms / max(n_frames, 1)
    hz = 1000.0 / max(ms_per_frame, 1e-6)
    mkpath(dirname(save_path))
    Makie.save(save_path, fig)
    println("Streaming benchmark: ", n_frames, " frames, ", round(ms_per_frame; digits = 2), " ms/frame (", round(hz; digits = 1), " Hz) -> ", save_path)
end
