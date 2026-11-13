module TemporalGrammarLive20261113

using WGLMakie, Grafico, Random, Statistics
using Bonito: Bonito, DOM, App, @js_str

include("model.jl")
include("projection.jl")

WGLMakie.activate!(framerate = 60, resize_to = :parent)
include("scene.jl")

app = App(; title = "Temporal grammar experiment") do session
    command = Observable{Any}(nothing)
    state = Observable(Dict("sequence" => 0, "fraction" => 0.0, "progress" => 0.0, "arrived" => 0))
    Grafico.seek!(playback, 0.0 * Grafico.duration(playback))
    Bonito.on(session, command) do request
        request === nothing && return
        fraction = clamp(Float64(request["fraction"]), 0.0, 1.0)
        Grafico.seek!(playback, fraction * Grafico.duration(playback))
        frame = sample_transfer(plan, progress[])
        state[] = Dict("sequence" => request["sequence"], "fraction" => fraction,
                       "progress" => progress[], "arrived" => sum(frame.counts))
    end
    plot = DOM.div(probe_figure; class = "experiment-plot")
    scrubber = DOM.input(; type = "range", min = "0", max = "1", step = "0.001",
                        value = "0", aria_label = "Animation time")
    button = DOM.button("Play"; type = "button")
    controls = DOM.div(button, scrubber; class = "experiment-controls")
    root = DOM.main(plot, controls; class = "temporal-experiment")
    # Keep browser mechanics outside the scientific scene and motion model.
    implementation = read(joinpath(@__DIR__, "live.js"), String)
    setup = js"""
    const initialize = $(Bonito.JSCode(implementation));
    initialize($(root), $(scrubber), $(button), $(command), $(state), $(playback.seconds));
    """
    DOM.div(
        DOM.style("body{margin:0}.experiment-plot{width:100%;height:550px}.experiment-controls{display:flex;gap:1em;padding:1em}.experiment-controls input{flex:1}"),
        root, setup,
    )
end

server = Bonito.Server(app, "127.0.0.1", 8771)
println("Temporal grammar experiment: http://127.0.0.1:8771")

end
