"""The plot windows of the browser, drawn with GLMakie. Loaded when GLMakie is loaded."""
module DataBrowserPlotsGLMakieExt

using GLMakie: Figure

import DataBrowserAPI
import DataBrowserCore.Workspace
using DataBrowserAPI: @timed_dbg
import DataBrowserGUI
const Browser = DataBrowserGUI.Browser

using DataBrowserPlots:
    RegisteredPlot,
    plot_kind_label,
    plot_data!,
    registered_plot_kinds,
    setup_plot
import DataBrowserPlots: embed

include("MakieIntegration.jl")
using .MakieImguiIntegration

embed(figure::Figure, id::String) = MakieFigure(id, figure; auto_resize_x=true, auto_resize_y=true)
include("FigureView.jl")
include("PlotView.jl")
include("Renderer.jl")
include("BuilderView.jl")
include("PlotsExtension.jl")

function __init__()
    Browser.register_gui_extension!(PlotsExtension)
end

end
