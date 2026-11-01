import CImGui as ig
using DataBrowserGUI: GuiExtension
using DataBrowserGUI.Browser: Browser

# The packages that the plot-window extension of DataBrowserPlots needs. GLMakie is first: see
# `_load_plot_windows`.
const PLOT_WINDOW_PACKAGES = (
    Base.PkgId(Base.UUID("e9467ef8-e4e7-5192-8a1a-b1aee30e663a"), "GLMakie"),
    Base.PkgId(Base.UUID("cbdf2221-f076-402e-a563-3d30da359d67"), "AlgebraOfGraphics"),
)

"""
Loads AlgebraOfGraphics and GLMakie on a worker thread after the browser shows its first frame, when
they are in the active environment and not loaded yet. The plot windows of DataBrowserPlots join the
browser when both have loaded. Until then, the saved windows that wait for their visualizer show
"Loading".
"""
mutable struct PlotWindowsLoader <: GuiExtension
    task::Union{Nothing,Task}
    started::Bool
end
PlotWindowsLoader() = PlotWindowsLoader(nothing, false)

function Browser.draw!(loader::PlotWindowsLoader, state)
    if !loader.started
        loader.started = true
        Base.get_extension(DataBrowserPlots, :DataBrowserPlotsGLMakieExt) === nothing || return nothing
        absent = [package.name for package in PLOT_WINDOW_PACKAGES if Base.locate_package(package) === nothing]
        if !isempty(absent)
            @warn "The browser has no plot windows: add $(join(absent, " and ")) to the active environment"
            return nothing
        end
        # Read on the UI thread, after the browser has set it.
        policy = _activation_policy()
        loader.task = Threads.@spawn :default _load_plot_windows(policy)
    end
    task = loader.task
    task === nothing && return nothing
    if istaskdone(task)
        loader.task = nothing
        try
            fetch(task)
        catch error
            @error "Could not load the plot windows" exception=(error, catch_backtrace())
        end
        return nothing
    end
    for window in Browser._waiting_windows(state)
        ig.Begin("$(window.visualizer)###$(window.id)") && ig.TextDisabled("Loading")
        ig.End()
    end
    return nothing
end

"""
Load GLMakie, then AlgebraOfGraphics, which loads the plot-window extension. GLMakie hides the Dock
icon of the process when it loads, on macOS; `policy` sets back the one the browser had, before the
rest loads.
"""
# FIXME: the browser stops drawing for 1–2 s several times while the packages load, and for about
# 9 s after: the first plot window compiles on the UI thread, and the loaded packages invalidate
# browser code that the next frames compile again.
function _load_plot_windows(policy::Union{Nothing,Clong})::Nothing
    glmakie, aog = PLOT_WINDOW_PACKAGES
    Base.require(glmakie)
    # FIXME: AppKit expects this call on the main thread. GLMakie makes the same call on this thread.
    policy === nothing || _set_activation_policy(policy)
    Base.require(aog)
    return nothing
end

# The macOS activation policy says whether the process has a Dock icon. Other systems have none.
function _shared_application()::Ptr{Cvoid}
    class = @ccall objc_getClass("NSApplication"::Cstring)::Ptr{Cvoid}
    selector = @ccall sel_registerName("sharedApplication"::Cstring)::Ptr{Cvoid}
    return @ccall objc_msgSend(class::Ptr{Cvoid}, selector::Ptr{Cvoid})::Ptr{Cvoid}
end

function _activation_policy()::Union{Nothing,Clong}
    Sys.isapple() || return nothing
    selector = @ccall sel_registerName("activationPolicy"::Cstring)::Ptr{Cvoid}
    return @ccall objc_msgSend(_shared_application()::Ptr{Cvoid}, selector::Ptr{Cvoid})::Clong
end

function _set_activation_policy(policy::Clong)::Nothing
    selector = @ccall sel_registerName("setActivationPolicy:"::Cstring)::Ptr{Cvoid}
    @ccall objc_msgSend(_shared_application()::Ptr{Cvoid}, selector::Ptr{Cvoid}, policy::Clong)::Bool
    return nothing
end
