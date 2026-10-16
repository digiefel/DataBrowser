import CImGui
import Base.ScopedValues

"""Fonts owned by one browser's ImGui context."""
struct _GUIFonts
    interface::Ptr{CImGui.lib.ImFont}
    code::Ptr{CImGui.lib.ImFont}
end

# Bind these while running the browser. Its render task inherits the binding; other browsers
# have their own binding. The ImGui context owns and frees the native font objects.
const _CURRENT_FONTS = ScopedValues.ScopedValue{_GUIFonts}()

"""
    with_font(f, role::Symbol)

Draw with the browser's `:interface` or `:code` font for the duration of `f()`. Return its result
and restore the previous font, including when `f` throws. Calls may be nested.

Use this during browser drawing. The interface font (Lexend) is the default for controls and
labels. The code font (JuliaMono) is for table content, printed values, source code, and other
text that needs equal character widths. Keep a visualizer's controls outside its code-font block.

```julia
with_font(:code) do
    CImGui.TextUnformatted(text)
end
```

Fonts belong to `DataBrowserGUI`; using them does not require a workspace or browser-state handle.
"""
function with_font(f::Function, role::Symbol)
    role in (:interface, :code) || throw(ArgumentError(
        "Unknown font role $(repr(role)); use :interface or :code",
    ))
    isassigned(_CURRENT_FONTS) || throw(ArgumentError(
        "with_font must be called during browser drawing",
    ))
    fonts = _CURRENT_FONTS[]
    font = role === :interface ? fonts.interface : fonts.code
    CImGui.PushFont(font, 0.0f0)
    try
        return f()
    finally
        CImGui.PopFont()
    end
end

"""Load the bundled fonts into the current ImGui context."""
function _load_fonts!()::_GUIFonts
    assets = joinpath(pkgdir(@__MODULE__), "assets")
    atlas = unsafe_load(CImGui.GetIO().Fonts)
    interface = CImGui.AddFontFromFileTTF(atlas, joinpath(assets, "Lexend-Regular.ttf"), 13.0f0)

    # Keep scientific labels readable when Lexend lacks a character. Earlier sources take
    # precedence, so ordinary interface text keeps Lexend's proportional character widths.
    merge = CImGui.lib.ImFontConfig_ImFontConfig()
    try
        merge.MergeMode = true
        CImGui.AddFontFromFileTTF(atlas, joinpath(assets, "JuliaMono-Regular.ttf"), 13.0f0, merge)
        # Icons fill their font size; load them smaller and move them onto the text baseline.
        merge.GlyphOffset = CImGui.ImVec2(0.0f0, 1.0f0)
        CImGui.AddFontFromFileTTF(atlas, joinpath(assets, "lucide.ttf"), 10.0f0, merge)
    finally
        CImGui.lib.ImFontConfig_destroy(merge)
    end

    code = CImGui.AddFontFromFileTTF(atlas, joinpath(assets, "JuliaMono-Regular.ttf"), 13.0f0)
    return _GUIFonts(interface, code)
end
