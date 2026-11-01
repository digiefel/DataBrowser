"""
DataBrowser and all its parts. `using DataBrowser` loads DataBrowserAPI, DataBrowserRecipes,
DataBrowserSources, DataBrowserCore, DataBrowserPlots and DataBrowserGUI, and exports the names
that each of them exports.
"""
module DataBrowser

using PrecompileTools
using Reexport

@reexport using DataBrowserAPI
@reexport using DataBrowserRecipes
@reexport using DataBrowserSources
@reexport using DataBrowserCore
@reexport using DataBrowserPlots
@reexport using DataBrowserGUI

include("PlotWindows.jl")
include("Precompile.jl")

__init__() = DataBrowserGUI.register_gui_extension!(PlotWindowsLoader)

end
