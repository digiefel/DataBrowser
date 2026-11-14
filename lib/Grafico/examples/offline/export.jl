module GraficoObservableWGLProbe

using WGLMakie, Grafico, Base64
using Bonito: Bonito, App, DOM, @js_str
import JSON

WGLMakie.activate!(framerate = 60, resize_to = :parent)
output = joinpath(@__DIR__, "output")
fixture_json = read(joinpath(output, "native-reference.json"), String)
fixture = JSON.parse(fixture_json)
include("author.jl")
include("lower-scene.jl")
prepared = prepare_scene(cloud; outputs = (; rows, area), figure_kw = (size = (800, 600),))
fig = prepared.figure
native_plots = prepared.native_plots
lookup_source = Any[Bonito.JSString("[")]
for (index, plot) in enumerate(native_plots)
    index == 1 || push!(lookup_source, Bonito.JSString(","))
    push!(lookup_source, plot)
end
push!(lookup_source, Bonito.JSString("]"))
native_lookup = Bonito.JSCode(lookup_source)
@assert [(b.plot, b.key, b.output, b.format) for b in prepared.bindings] ==
        [(b["plot"], b["key"], b["output"], b["format"]) for b in fixture["bindings"]]
wasm_base64 = base64encode(read(joinpath(output, "kernels.wasm")))
implementation = "(() => {" * (read(joinpath(output, "bridge-runtime.js"), String) * read(joinpath(@__DIR__, "value-runtime.js"), String) * read(joinpath(@__DIR__, "observable-runtime.js"), String) * read(joinpath(@__DIR__, "motion-runtime.js"), String) * read(joinpath(@__DIR__, "render-runtime.js"), String)) * "return " * read(joinpath(@__DIR__, "offline.js"), String) * ";})()"

app = App(; title = "Grafico: offline WGL and compiled Julia") do session
    root = DOM.main(
        DOM.div(fig; class = "plot"),
        DOM.div(; id = "controls"),
    )
    setup = js"""
    (async () => {
    const initialize = $(Bonito.JSCode(implementation));
    const groups = await Promise.all($(native_lookup));
    const plots = groups.flat().map(mesh => mesh.plot_object);
    await initialize($(root), plots, $(wasm_base64), JSON.parse($(fixture_json)));
    })().catch(error => { window.graficoOfflineError = String(error); console.error(String(error)); });
    """
    DOM.div(
        DOM.style("body{margin:0;font:16px system-ui}.plot{width:100%;height:600px}#controls{padding:1rem;display:grid;gap:.6rem}label{display:flex;gap:1em;align-items:center}label input{flex:1}"),
        root, setup,
    )
end
exported_session = Bonito.export_static(joinpath(output, "offline.html"), app)
# Bonito renders an error page when its app factory fails. Surface that failure
# before reporting that a bundle was written; browser initialization is checked separately.
isready(exported_session)
println("GRAFICO_OFFLINE_WGL_READY bytes=", filesize(joinpath(output, "offline.html")))

end
