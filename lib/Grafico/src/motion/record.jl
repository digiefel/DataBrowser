# Recording and printing sample the same plan without changing the author's
# current state, including when rendering or saving fails.
function _with_motion_state(f, planned::MotionPlan)
    originals = [_motion_copy(channel.observable[]) for channel in planned.channels]
    old_time = planned.time[]
    try
        f()
    finally
        for (channel, value) in zip(planned.channels, originals)
            Makie.Observables.setexcludinghandlers!(channel.observable, value)
        end
        Makie.Observables.setexcludinghandlers!(planned.time, old_time)
        foreach(channel -> notify(channel.observable), planned.channels)
        notify(planned.time)
    end
end

function _motion_record_times(planned::MotionPlan, framerate)
    rate = _motion_seconds(framerate; positive = true, name = "framerate")
    stop = duration(planned)
    times = collect(0:1/rate:stop)
    push!(times, stop)
    for channel in planned.channels, segment in channel.segments
        push!(times, segment.start, segment.stop)
    end
    sort!(unique!(times))
end

"""
    record(figure, path, playback::MotionPlan; framerate=60,
           still=nothing, still_at=Grafico.duration(playback))

Record a planned motion through Makie's existing `record` function. An `.html`
path writes a self-contained WGLMakie animation with playback and seeking;
load `WGLMakie` first. Other formats use Makie's movie recorder.

`still="final.svg"` also saves a vector print state through CairoMakie; load
`CairoMakie` to use it. `still_at` selects its time and defaults to the end.
The figure and source Observables return to their previous state after export.

HTML records native renderer values at `framerate`, including camera, ticks,
layout and drawing objects that appear later. Playback needs no Julia process.
It reproduces the recorded timeline; it does not export arbitrary Julia event
callbacks or compute new scientific results in response to browser controls.
"""
function Makie.record(figure::Makie.Figure, path::AbstractString, planned::MotionPlan;
                      framerate = 60, still = nothing, still_at = duration(planned), kwargs...)
    _motion_seconds(framerate; positive = true, name = "framerate")
    print_time = _motion_seconds(still_at; name = "still_at")
    print_time <= duration(planned) || throw(ArgumentError("still_at exceeds the animation's duration."))
    cairo = if still === nothing
        nothing
    else
        extension = Base.get_extension(@__MODULE__, :GraficoCairoMakieExt)
        extension === nothing && throw(ArgumentError("Load CairoMakie to export a vector still."))
        extension
    end
    html = lowercase(splitext(path)[2]) === ".html"
    wgl = html ? Base.get_extension(@__MODULE__, :GraficoWGLMakieExt) : nothing
    html && wgl === nothing && throw(ArgumentError("Load WGLMakie to export an HTML animation."))
    _with_motion_state(planned) do
        if html
            wgl.record_html(figure, path, planned; framerate, kwargs...)
        else
            frames = max(1, ceil(Int, duration(planned) * framerate))
            times = range(0, duration(planned); length = frames + 1)
            Makie.record(figure, path, times; framerate, kwargs...) do time
                seek!(planned, time)
            end
        end
        if still !== nothing
            seek!(planned, print_time)
            Makie.update_state_before_display!(figure)
            cairo.save_still(still, figure)
        end
    end
    path
end
