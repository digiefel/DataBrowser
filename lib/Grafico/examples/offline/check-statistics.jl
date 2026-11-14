module GraficoPortableStatisticsChecks

using Grafico, Makie, WasmTarget
import JSON
include("lower-observables.jl")
include("lower-scene.jl")

roots = Any[]
bindings = Dict{String,WasmTarget.RootBindings}()
configurations = (
    (name = "counts", weighted = false, options = (bins = range(0, 1; length = 7),)),
    (name = "density", weighted = false, options = (bins = range(0, 1; length = 7), closed = :right, normalization = :pdf)),
    (name = "weighted", weighted = true, options = (bins = range(0, 1; length = 7), normalization = :probability)),
    (name = "automatic_edges", weighted = false, options = (bins = 7,)),
)
fixtures = map(configurations) do configuration
    rows = Observable((current = [0.1, 0.2, 0.5, 0.8], weight = [1., 2., 1., 3.]))
    channels = configuration.weighted ? mapping(:current; weights = :weight) : mapping(:current)
    analysis = Grafico.histogram(; configuration.options...)
    declaration = data(rows) * channels * analysis
    sources = scene_observables(spec(Grafico._retained_plot(declaration)))
    @assert length(sources) == 3
    graph = Grafico._observable_graph(sources)
    names = ("centers", "weights", "widths")
    indices = Dict(name => index for (name, index) in zip(names, graph.outputs))
    wire = lower_observable_graph(graph, indices, IdDict(rows => "rows"), roots, bindings)
    cases = map((3, 17, 127)) do count
        shift = configuration.name == "automatic_edges" ? 2.0 : 0.5
        values = (current = [shift + 0.3sin(0.71i) for i in 1:count],
                  weight = [0.2 + i / count for i in 1:count])
        native = spec(data(values) * channels * analysis)
        plot = only(last(only(native.content)).plots)
        columns = (plot.args..., plot.kwargs[:width])
        expected = Dict(name => WasmTarget.Bridge.value_to_tree(
            wire.nodes[wire.outputs[name] + 1].descriptor, value)
            for (name, value) in zip(names, columns))
        (; rows = values, expected)
    end
    (; name = configuration.name, wire, cases)
end

diagnostics = WasmTarget.WasmDiagnostic[]
bytes = WasmTarget.compile_multi(roots; root_bindings = bindings, diagnostics_sink = diagnostics)
isempty(diagnostics) || error("Statistics compilation produced diagnostics: $diagnostics")
output = joinpath(@__DIR__, "output")
mkpath(output)
write(joinpath(output, "statistics.wasm"), bytes)
write(joinpath(output, "statistics.json"), JSON.json(fixtures))
println("GRAFICO_STATISTICS_READY configurations=", length(fixtures), " bytes=", length(bytes))

end
