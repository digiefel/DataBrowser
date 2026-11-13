# Internal export experiment. The numeric ABI is deliberately checked here;
# accepting a MotionPlan does not imply every Makie value is portable yet.
function lower_motion(planned, names, add_kernel!)
    mix = add_kernel!(Grafico._motion_mix, (Float64, Float64, Float64))
    channels = map(planned.channels) do channel
        eltype(channel.observable) === Float64 ||
            error("The browser probe currently exports Float64 motion channels.")
        segments = map(channel.segments) do segment
            curve = segment.curve === nothing ? nothing :
                add_kernel!(segment.curve, (Float64, Float64))
            ease = segment.curve === nothing ? add_kernel!(segment.ease, (Float64,)) : nothing
            (; start = segment.start, stop = segment.stop, initial = segment.initial,
               target = segment.target, curve, ease)
        end
        (; name = names[channel.observable], initial = channel.initial, segments)
    end
    (; duration = Grafico.duration(planned), channels, mix)
end
