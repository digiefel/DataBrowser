import CImGui as ig
using DataBrowserGUI: GuiExtension
using DataBrowserGUI.Browser: Browser

# The package that loads the plot-window extension of DataBrowserPlots, with DataBrowserGUI.
const GLMAKIE = Base.PkgId(Base.UUID("e9467ef8-e4e7-5192-8a1a-b1aee30e663a"), "GLMakie")

"""
Loads GLMakie on a worker thread after the browser shows its first frame, when it is in the active
environment and not loaded yet. The plot windows join the browser when it has loaded. Until then,
the saved windows that wait for their visualizer show "Loading".
"""
mutable struct PlotWindowsLoader <: GuiExtension
    task::Union{Nothing,Task}
    started::Bool
end
PlotWindowsLoader() = PlotWindowsLoader(nothing, false)

function Browser.draw!(loader::PlotWindowsLoader, state)
    if !loader.started
        loader.started = true
        Base.get_extension(DataBrowserPlots, :DataBrowserPlotsGUIExt) === nothing || return nothing
        if Base.locate_package(GLMAKIE) === nothing
            @warn "The browser has no plot windows: add GLMakie to the active environment"
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
Load GLMakie, which loads the plot-window extension. GLMakie hides the Dock icon of the process
when it loads, on macOS; `policy` sets back the one the browser had.
"""
# FIXME: the browser stops drawing for about 1.5 s while GLMakie loads, and 0.8 s after. Browser
# code that compiles for the first time while it loads, such as the rows of the tree, compiles again
# after each package that loads meanwhile. Packages outside the dependencies of the plot-window
# extension, such as DataFrames, make Julia discard its compiled warmup.
function _load_plot_windows(policy::Union{Nothing,Clong})::Nothing
    Base.require(GLMAKIE)
    # FIXME: AppKit expects this call on the main thread. GLMakie makes the same call on this thread.
    policy === nothing || _set_activation_policy(policy)
    ## The methods that GLMakie adds discard the compiled drawing of a Table window. Compile it again
    ## here, so that the first Table window does not stop the browser for a second.
    precompile(DataBrowserAPI.draw!, (Browser.TableView, Browser.WindowContext))
    precompile(DataBrowserAPI.draw_header!, (Browser.TableView, Browser.WindowContext))
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
