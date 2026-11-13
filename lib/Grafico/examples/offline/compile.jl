module GraficoObservableCompilerProbe

using WasmTarget
import JSON
using Grafico
include("author.jl")
include("lower-motion.jl")
include("lower-observables.jl")

output = joinpath(@__DIR__, "output")
mkpath(output)
K = GraficoPortableKernels
roots = Any[]
root_bindings = Dict{String,WasmTarget.RootBindings}()
function add_kernel!(f, signature)
    existing = findfirst(root -> root[1] === f && root[2] == signature, roots)
    existing === nothing || return roots[existing][3]
    name = "motion_$(length(roots) + 1)"
    push!(roots, (f, signature, name))
    if fieldcount(typeof(f)) > 0
        constants = Dict(key => getfield(f, key) for key in fieldnames(typeof(f)))
        root_bindings[name] = WasmTarget.RootBindings(;
            captured_constants = constants, elide_closure_context = true)
    end
    name
end
motion_wire = lower_motion(playback, IdDict(angle => "angle", stretch => "stretch"), add_kernel!)
input_names = IdDict(angle => "angle", stretch => "stretch", source => "source",
                     lower => "lower", upper => "upper", time => "time", signal => "signal")
graph_wire = lower_observables((; rows, area), input_names, roots, root_bindings)
write(joinpath(output, "bridge-runtime.js"),
    "function createCompilerBridge(ex) {" * WasmTarget.Bridge.WALK_JS *
    WasmTarget.Bridge.BUILD_JS * "return {walk, build};}")
motion_cases = map((0.0, 0.137, 1.27, 2.41, 3.0, 3.137, 4.131, 5.413, 6.807, 7.0, 7.73, 9.0)) do time
    Grafico.seek!(playback, time)
    (; time, angle = angle[], stretch = stretch[])
end
Grafico.seek!(playback, 0)
diagnostics = WasmTarget.WasmDiagnostic[]
# The temporary compiler copy passes external_linkage=false to Julia's collector.
# This collects every dependency instead of linking to native Julia image code.
elapsed = @elapsed bytes = WasmTarget.compile_multi(roots;
    diagnostics_sink = diagnostics, root_bindings = root_bindings)
isempty(diagnostics) || throw(ErrorException("Export could not compile every computation: " * join(string.(diagnostics), "; ")))
write(joinpath(output, "kernels.wasm"), bytes)

points = [(x = 0.7 * cos(t) + 0.15 * cos(3t), y = 0.5 * sin(t))
          for t in range(0, 2π; length = 81)[1:end-1]]
fixture_time = collect(range(0.0, 1.0; length = 1025))
fixture_signal = @. sin(6π * fixture_time) + 0.3 * fixture_time + 0.1 * cos(31π * fixture_time)

cloud_cases = [
    (angle = angle, stretch = stretch,
     x = [K.cloud_x(angle, stretch, p.x, p.y) for p in points],
     y = [K.cloud_y(angle, stretch, p.x, p.y) for p in points])
    for angle in (0.13, 0.87, 2.41, 5.91), stretch in (0.55, 1.13, 1.77)
]
integral_cases = [
    (lower = lower, upper = upper, value = K.interval_integral(fixture_time, fixture_signal, lower, upper))
    for (lower, upper) in ((0.031, 0.413), (0.173, 0.867), (0.003, 0.997),
                           (0.723, 0.723), (0.81, 0.23), (-0.12, 1.13))
]
swing_cases = [(start = 0.37, progress = u, value = K.swing(0.37, u))
               for u in (0.0, 0.031, 0.17, 0.413, 0.807, 1.0)]
# Changing a data source is an ordinary Observable update, including its length.
source_cases = map((0, 3, 127, 257)) do count
    values = [(x = -0.9 + 0.09mod(i - 1, 21), y = -0.9 + 0.09div(i - 1, 21)) for i in 1:count]
    source[] = values
    angle[], stretch[] = 0.371, 0.913
    (; points = values, angle = angle[], stretch = stretch[], x = copy(rows[].x), y = copy(rows[].y))
end
source[] = points
Grafico.seek!(playback, 0)

fixture = (; source_cases, points, time = fixture_time, signal = fixture_signal, graph_wire, cloud_cases, integral_cases, swing_cases, motion_wire, motion_cases,
            compiler_seconds = elapsed, module_bytes = length(bytes),
            diagnostic_count = length(diagnostics),
            compiler_version = string(Base.pkgversion(WasmTarget)), compiler_discovery = "trim",
            compiler_patch = "wasmtarget-julia-1.13.3.patch",
            julia_version = string(VERSION))
write(joinpath(output, "native-reference.json"), JSON.json(fixture))
println("GRAFICO_WASM_KERNEL_READY bytes=", length(bytes), " diagnostics=", length(diagnostics),
        " seconds=", elapsed)
for diagnostic in diagnostics
    println(diagnostic)
end

end
