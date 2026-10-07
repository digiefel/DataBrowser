"""The plot windows of the browser, drawn with GLMakie. Loaded when GLMakie is loaded."""
module DataBrowserPlotsGLMakieExt

using GLMakie: Figure

import DataBrowserAPI
import DataBrowserAPI: AbstractDataItem
import DataBrowserCore.Catalogs: ItemKey
import DataBrowserCore.Workspace
using DataBrowserAPI: @timed_dbg
import DataBrowserGUI
const Browser = DataBrowserGUI.Browser

using DataBrowserPlots:
    PlotKind,
    RegisteredPlot,
    _plot_recipes,
    plot_kind_from_name,
    plot_kind_label,
    plot_kind_name,
    plot_kinds,
    plot_data!,
    registered_plot_kinds,
    setup_plot

include("MakieIntegration.jl")
using .MakieImguiIntegration

include("PlotState.jl")
include("PlotPanel.jl")
include("TablePlotPanel.jl")
include("PlotsExtension.jl")

function __init__()
    Browser.register_gui_extension!(PlotsExtension)
end

end
