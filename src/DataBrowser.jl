"""DataBrowser umbrella: public API re-exports and default wiring."""
module DataBrowser

using PrecompileTools
using Reexport

@reexport using DataBrowserAPI
@reexport using DataBrowserRecipes
@reexport using DataBrowserSources
@reexport using DataBrowserCore
@reexport using DataBrowserPlots
@reexport using DataBrowserGUI

using DataBrowserAPI: project_name
import DataBrowserCache as Cache
import DataBrowserCore.Workspace as Workspace
import DataBrowserGUI: Browser

include("Precompile.jl")

end
