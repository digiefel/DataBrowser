"""The plot windows of the browser, drawn with GLMakie. Loaded when GLMakie is loaded."""
module DataBrowserPlotsGLMakieExt

using GLMakie: Figure

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

function __init__()
    Browser.register_gui_extension!(PlotsExtension)
end

end
