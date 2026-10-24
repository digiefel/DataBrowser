module Browser

using ..DataBrowserGUI: with_font, _load_fonts!, _CURRENT_FONTS
import Base.ScopedValues

include("Browser/timing.jl")
include("Browser/Extensions.jl")
include("Browser/State.jl")
include("Browser/api.jl")
include("Browser/Performance.jl")
include("Browser/Tags.jl")
include("Browser/Persistence.jl")
include("Browser/Operations.jl")
include("Browser/Windows.jl")
include("Gui/Utilities.jl")
include("Gui/TagStyling.jl")
include("Gui/DataGrid.jl")
include("Gui/ListPicker.jl")
include("Gui/TableView.jl")
include("Gui/ValueView.jl")
include("Gui/ImPlotViews.jl")
include("Gui/WindowPicture.jl")
include("Gui/VisualizerWindows.jl")
include("Gui/TreePanel.jl")
include("Gui/InfoModal.jl")
include("Gui/DebugTools.jl")
include("Gui/Layout.jl")
include("Gui/PerformanceWindow.jl")

export open_browser, close_browser!, BrowserSession

end
