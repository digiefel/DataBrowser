# Live 2-channel Observable waveform and peak marker updated at 60 Hz.

using WgpuMakie

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

screen = display(fig)

@async let xs = xs, ch1 = ch1, ch2 = ch2, peaks = peaks, screen = screen
    phase = 0.0f0
    while isopen(screen)
        phase += 0.14f0
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
        peaks.val[1] = Point2f(xs[best_i], best_y)
        notify(ch1)
        notify(ch2)
        notify(peaks)
        sleep(1 / 60)
    end
end

isinteractive() || wait(screen)
