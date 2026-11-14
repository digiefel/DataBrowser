module GraficoPortableMotionChecks

using Grafico, Makie, WasmTarget
import JSON
include("compile-values.jl")
include("lower-motion.jl")

count = Observable(Int64(2))
visible = Observable(false)
window = Observable((0.0, 1.0))
colour = Observable(RGBAf(0.1, 0.3, 0.8, 1))
values = Observable([0.0, 1.0, 2.0])
small = Observable(Float32(0.25))
box = Observable(Makie.Rect2f(0, 0, 1, 1))
model = Observable((center = (0.0, 1.0), gain = 1.0))

motion = sequence(
    together(
        to(count => 13, visible => true, window => (2.0, 4.0); duration = 2.2),
        to(colour => RGBAf(0.8, 0.2, 0.4, 0.5), values => [2.0, 4.0, 1.0]; duration = 1.7),
        to(small => Float32(0.8), box => Makie.Rect2f(2, 1, 3, 2),
           model => (center = (2.0, -1.0), gain = 0.3); duration = 2.0),
    ),
    hold(0.3),
    along(window, (start, u) -> (start[1] + u^2, start[2] + u^2); duration = 0.7),
)
planned = Grafico.plan(motion)
inputs = (; count, visible, window, colour, values, small, box, model)
names = IdDict(observable => string(name) for (name, observable) in pairs(inputs))
names[planned.time] = "time"
roots = Any[]
bindings = Dict{String,WasmTarget.RootBindings}()
description = lower_motion(planned, names, roots, bindings)

cases = map((0.0, 0.031, 0.137, 0.419, 0.813, 1.137, 1.7, 1.913, 2.2, 2.413, 2.5, 2.731, 3.137, 3.2)) do time
    Grafico.seek!(planned, time)
    encoded = Dict(channel.name => WasmTarget.Bridge.value_to_tree(channel.descriptor,
        inputs[Symbol(channel.name)][]) for channel in description.channels)
    (; time, values = encoded)
end
Grafico.seek!(planned, 0)
diagnostics = WasmTarget.WasmDiagnostic[]
bytes = WasmTarget.compile_multi(roots; root_bindings = bindings, diagnostics_sink = diagnostics)
isempty(diagnostics) || error("Motion compilation produced diagnostics: $(diagnostics)")
output = joinpath(@__DIR__, "output")
mkpath(output)
write(joinpath(output, "motion-values.wasm"), bytes)
write(joinpath(output, "motion-values.json"), JSON.json((; description, cases)))
println("GRAFICO_TYPED_MOTION_READY channels=", length(description.channels), " bytes=", length(bytes))

end
