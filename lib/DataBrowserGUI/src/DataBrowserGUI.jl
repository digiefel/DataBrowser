"""
CImGui browser shell and panels.

Browser controls use the interface font. GUI components can use [`with_font`](@ref) to draw table
content, printed values, or code with the code font, and then return to the interface font.
"""
module DataBrowserGUI

include("Fonts.jl")
export with_font

include("CodeFile.jl")
export CodeFile

include("CodeText.jl")

include("TableModel.jl")
include("Browser.jl")

using .Browser: open_browser, close_browser!, BrowserSession, gui_timings, reset_timings!
using .Browser: wait_browser_ready
export wait_browser_ready
export open_browser, close_browser!, BrowserSession, gui_timings, reset_timings!

end
