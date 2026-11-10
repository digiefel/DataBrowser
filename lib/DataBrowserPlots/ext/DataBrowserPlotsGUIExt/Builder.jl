"""The plot builder window of the browser."""
module Builder

import CImGui as ig
import GLMakie.Makie as Makie

import DataBrowserAPI
using DataBrowserAPI: @timed_dbg, Setting
using DataBrowserCore: Selection
using DataBrowserGUI: CODE_COLORS, CodeFile, code_text, draw_code, edit!, ischanged_on_disk, isunsaved, load!, save!, with_font
using DataBrowserGUI.Browser: ListItem, ListPicker, render_list_picker!, guarded_draw, draw_colors
import DataBrowserAPI: draw!, prepare!, settings
using DataBrowserPlots: DataBrowserPlots, figure, mappings, scale_categories, scale_kinds
using ..DataBrowserPlotsGUIExt: DARK, FigureView
import ..DataBrowserPlotsGUIExt: theme_button
import ..DataBrowserPlotsGUIExt: build!

# Icons of the Lucide font that DataBrowserGUI loads with the interface font.
const ICON_EYE = "\ue0ba"
const ICON_EYE_OFF = "\ue0bb"
const ICON_INFO = "\ue0f9"
const ICON_PLUS = "\ue13d"
const ICON_X = "\ue1b2"
const ICON_CHEVRON_DOWN = "\ue06d"
const ICON_CHEVRON_RIGHT = "\ue06f"
const ICON_THEME = "\ue59f"    # swatch-book
const ICON_PALETTE = "\ue1dd"  # palette
const ICON_TEXT = "\ue3d9"     # case-sensitive
const ICON_SETTING = "\ue29a"  # sliders-horizontal
const ICON_BLOCK = "\ue471"    # layout-panel-top
const ICON_PLOT = "\ue48a"     # chart-scatter
const ICON_FLIP = "\ue35e"     # flip-horizontal-2
const ICON_TYPE = "\ue198"     # type
const ICON_HASH = "\ue0ef"     # hash
const ICON_RULER = "\ue14b"    # ruler
const ICON_TAG = "\ue17f"      # tag
const ICON_SHAPES = "\ue4b3"   # shapes
const ICON_RAINBOW = "\ue4c2"  # rainbow
const ICON_PIPETTE = "\ue13b"  # pipette
const ICON_ORDERED = "\ue1d1"  # list-ordered
const ICON_COLUMN = "\ue473"   # variable

include("PlotCode.jl")
include("BuilderView.jl")
include("CodeEdits.jl")
include("Drawing.jl")
include("Widgets.jl")
include("Panel.jl")

end
