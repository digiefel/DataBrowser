# Timing and values come from the native plan. Interpolation, easing and authored
# trajectories use the same compiled Julia functions as ordinary computations.
struct TypedMotionFunction{F,T}
    function_value::F
end
(call::TypedMotionFunction{F,T})(values...) where {F,T} = convert(T, call.function_value(values...))

function lower_motion(planned, names, roots, bindings)
    channels = map(planned.channels) do channel
        T = eltype(channel.observable)
        isconcretetype(T) || throw(ArgumentError("Export needs a concrete motion value type; got $T."))
        argument_descriptor = transport_type!(T, :argument, roots, bindings)
        descriptor = transport_type!(T, :result, roots, bindings)
        encode(value) = WasmTarget.Bridge.value_to_tree(argument_descriptor, value)
        mix = add_wasm_root!(roots, bindings, TypedMotionFunction{typeof(Grafico._motion_mix),T}(Grafico._motion_mix),
                             (T, T, Float64); prefix = "motion")
        segments = map(channel.segments) do segment
            curve = if segment.curve === nothing
                nothing
            else
                Grafico._check_observable_capture(segment.curve)
                add_wasm_root!(roots, bindings, TypedMotionFunction{typeof(segment.curve),T}(segment.curve),
                               (T, Float64); prefix = "motion")
            end
            ease = segment.curve === nothing ?
                add_wasm_root!(roots, bindings, segment.ease, (Float64,); prefix = "motion") : nothing
            (; start = segment.start, stop = segment.stop, initial = encode(segment.initial),
               target = encode(segment.target), curve, ease)
        end
        (; name = names[channel.observable], initial = encode(channel.initial),
           descriptor, argument_descriptor, mix, segments)
    end
    (; duration = Grafico.duration(planned), channels, time_name = get(names, planned.time, nothing))
end
