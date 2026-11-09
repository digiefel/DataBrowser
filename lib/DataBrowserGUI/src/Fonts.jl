import CImGui
import Base.ScopedValues

"""Fonts owned by one browser's ImGui context."""
struct _GUIFonts
    interface::Ptr{CImGui.lib.ImFont}
    code::Ptr{CImGui.lib.ImFont}
    interface_bold::Ptr{CImGui.lib.ImFont}
    code_bold::Ptr{CImGui.lib.ImFont}
end

# Bind these while running the browser. Its render task inherits the binding; other browsers
# have their own binding. The ImGui context owns and frees the native font objects.
const _CURRENT_FONTS = ScopedValues.ScopedValue{_GUIFonts}()

"""
    with_font(f, role::Symbol; bold::Bool=false)

Draw with the browser's `:interface` or `:code` font, in its bold weight when `bold` is set, while
`f()` runs. Return the result of `f()` and go back to the font before, also when `f` throws. Calls
may be nested. Call it only while the browser draws.

The interface font (Lexend) is the default for controls and labels. The code font (JuliaMono) has
characters of equal width: use it for table content, printed values and code, and keep the
controls of a visualizer outside it.

```julia
with_font(:code) do
    CImGui.TextUnformatted(text)
end
```
"""
function with_font(f::Function, role::Symbol; bold::Bool=false)
    role in (:interface, :code) || throw(ArgumentError(
        "Unknown font role $(repr(role)); use :interface or :code",
    ))
    isassigned(_CURRENT_FONTS) || throw(ArgumentError(
        "with_font must be called during browser drawing",
    ))
    fonts = _CURRENT_FONTS[]
    font = role === :interface ? (bold ? fonts.interface_bold : fonts.interface) : (bold ? fonts.code_bold : fonts.code)
    CImGui.PushFont(font, 0.0f0)
    try
        return f()
    finally
        CImGui.PopFont()
    end
end

# The private-use range of Unicode, where the Lucide font has its icons. JuliaMono has glyphs of
# its own there, which it leaves to the icons. ImGui reads the ranges while the fonts are in use.
const _ICON_RANGE = CImGui.lib.ImWchar[0xe000, 0xf8ff, 0]

"""Load the bundled fonts into the current ImGui context."""
function _load_fonts!()::_GUIFonts
    assets = joinpath(pkgdir(@__MODULE__), "assets")
    atlas = unsafe_load(CImGui.GetIO().Fonts)
    ## The fonts of one weight: the interface font and the code font, each with the icons. ImGui keeps
    ## a copy of each configuration, so one configuration serves several fonts.
    function load(weight::String)
        merge = CImGui.lib.ImFontConfig_ImFontConfig()
        merge.MergeMode = true
        code_config = CImGui.lib.ImFontConfig_ImFontConfig()
        code_config.GlyphExcludeRanges = pointer(_ICON_RANGE)

        interface = CImGui.AddFontFromFileTTF(atlas, joinpath(assets, "Lexend-$weight.ttf"), 13.0f0)
        ## JuliaMono draws the characters that Lexend lacks, such as those of scientific labels. A
        ## merged font only adds characters, so Lexend keeps its own.
        merge.GlyphExcludeRanges = pointer(_ICON_RANGE)
        CImGui.AddFontFromFileTTF(atlas, joinpath(assets, "JuliaMono-$weight.ttf"), 13.0f0, merge)
        ## Icons fill their font size; they load smaller and move down onto the line of the text.
        merge.GlyphExcludeRanges = C_NULL
        merge.GlyphOffset = CImGui.ImVec2(0.0f0, 1.0f0)
        CImGui.AddFontFromFileTTF(atlas, joinpath(assets, "lucide.ttf"), 10.0f0, merge)

        code = CImGui.AddFontFromFileTTF(atlas, joinpath(assets, "JuliaMono-$weight.ttf"), 13.0f0, code_config)
        CImGui.AddFontFromFileTTF(atlas, joinpath(assets, "lucide.ttf"), 10.0f0, merge)

        CImGui.lib.ImFontConfig_destroy(merge)
        CImGui.lib.ImFontConfig_destroy(code_config)
        return interface, code
    end
    ## The regular weight loads first: ImGui takes the first font as the default.
    interface, code = load("Regular")
    interface_bold, code_bold = load("Bold")
    return _GUIFonts(interface, code, interface_bold, code_bold)
end
