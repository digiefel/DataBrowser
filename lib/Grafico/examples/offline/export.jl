module GraficoOfflineWGLProbe

using WGLMakie, Grafico, Base64
using Bonito: Bonito, App, DOM, @js_str
import JSON

WGLMakie.activate!(framerate = 60, resize_to = :parent)
output = joinpath(@__DIR__, "output")
fixture_json = read(joinpath(output, "native-reference.json"), String)
fixture = JSON.parse(fixture_json)
include("author.jl")
fig = figure(cloud; figure_kw = (size = (800, 600),))

function scatter_plots(plot)
    plot isa Scatter && return [plot]
    reduce(vcat, (scatter_plots(child) for child in plot.plots); init = Any[])
end
axis = only(filter(block -> block isa Axis, fig.content))
native_scatter = only(reduce(vcat, scatter_plots.(axis.scene.plots); init = Any[]))
wasm_base64 = base64encode(read(joinpath(output, "kernels.wasm")))
implementation = "(() => {" * read(joinpath(@__DIR__, "motion-runtime.js"), String) * "return " * read(joinpath(@__DIR__, "offline.js"), String) * ";})()"

app = App(; title = "Grafico: offline WGL and compiled Julia") do session
    root = DOM.main(
        DOM.div(fig; class = "plot"),
        DOM.div(; id = "controls"),
    )
    setup = js"""
    (async () => {
    const initialize = $(Bonito.JSCode(implementation));
    const [mesh] = await $(native_scatter);
    await initialize($(root), mesh.plot_object, $(wasm_base64), JSON.parse($(fixture_json)));
    })().catch(error => { window.graficoOfflineError = String(error); console.error(String(error)); });
    """
    DOM.div(
        DOM.style("body{margin:0;font:16px system-ui}.plot{width:100%;height:600px}#controls{padding:1rem;display:grid;gap:.6rem}label{display:flex;gap:1em;align-items:center}label input{flex:1}"),
        root, setup,
    )
end
Bonito.export_static(joinpath(output, "offline.html"), app)
println("GRAFICO_OFFLINE_WGL_READY bytes=", filesize(joinpath(output, "offline.html")))

end
