"""
The plot windows and the plot builder window of the browser, drawn with GLMakie. Loaded when
AlgebraOfGraphics and GLMakie are loaded.
"""
module DataBrowserPlotsGLMakieExt

using GLMakie: Axis, Figure, axislegend, cgrad, lines!, linkxaxes!, scatter!
using PrecompileTools: @compile_workload

import DataBrowserAPI
import DataBrowserCore.Workspace
using DataBrowserAPI: @timed_dbg
import DataBrowserGUI
const Browser = DataBrowserGUI.Browser

using DataBrowserPlots: registered_plots

include("MakieIntegration.jl")
using .MakieImguiIntegration

include("FigureView.jl")
include("PlotView.jl")
include("PlotsExtension.jl")
include("Builder.jl")

"""
A figure with the calls a registered plot usually makes: linked axes, a color per item, solid and
dashed lines, markers and a legend. The precompile workload builds and draws it, and the browser
draws it once before its first plot window, so that both compile the same code.
"""
function example_figure()::Figure
    voltage = collect(range(-1.0, 1.0; length=20))
    figure = Figure(size=(320, 240))
    current = Axis(figure[1, 1]; ylabel="Current (A)", title="I-V")
    magnitude = Axis(figure[2, 1]; xlabel="Voltage (V)", ylabel="|Current| (A)")
    linkxaxes!(current, magnitude)
    colors = cgrad(:tab10, 2; categorical=true)
    for (index, label) in enumerate(("a", "b"))
        values = index .* voltage .^ 3
        lines!(current, voltage, values; color=colors[index], linewidth=2, label)
        scatter!(current, voltage, values; color=colors[index], markersize=4)
        lines!(magnitude, voltage, abs.(values); color=colors[index], linestyle=:dash)
    end
    axislegend(current)
    return figure
end

@compile_workload MakieImguiIntegration.draw_in_hidden_window(example_figure())

function __init__()
    Browser.register_gui_extension!(PlotsExtension)
end

end
