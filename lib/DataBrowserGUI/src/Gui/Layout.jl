import GLFW
import CImGui as ig
import CImGui.CSyntax: @c

import DataBrowserCore.Workspace

"""Return whether the native GLFW window or `close_browser!` requested shutdown."""
function _window_close_requested(state::BrowserState)::Bool
    state.exit_requested && return true
    window = ig.current_window()
    window === nothing && return false
    return GLFW.WindowShouldClose(window)
end

# The Lucide icon font, version 1.52.0 (ISC licence, in `assets/lucide-LICENSE`). Its icons are
# characters in the private-use range, so a string can hold text and icons together.
const ICON_FAILED = "\ue084"   # circle-x
const ICON_COPY = "\ue09e"     # copy
const ICON_FILTER = "\ue0dc"   # funnel
const ICON_COLUMNS = "\ue099"  # columns-3
const ICON_TAG = "\ue17f"      # tag

"""Create the ImGui context with the docking/viewport configuration the browser needs."""
function _init_browser_context!()
    ig.set_backend(:GlfwOpenGL3)
    ctx = ig.CreateContext()
    io = ig.GetIO()
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_DockingEnable
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_ViewportsEnable
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_NavEnableKeyboard

    fonts = _load_fonts!()

    ig.StyleColorsDark()
    return ctx, fonts
end

"""
On macOS, promote the process to a regular foreground app so its window gets a Dock icon and shows
up in Cmd-Tab. When the renderloop is driven from the REPL the process can otherwise stay an
accessory app with no Dock presence. No-op off macOS; never throws, since a failure here must not
take down the render loop.
"""
function _promote_to_foreground_app()
    Sys.isapple() || return nothing
    try
        objc_class(name) = @ccall objc_getClass(name::Cstring)::Ptr{Cvoid}
        objc_sel(name) = @ccall sel_registerName(name::Cstring)::Ptr{Cvoid}
        nsapplication = objc_class("NSApplication")
        nsapplication == C_NULL && return nothing
        app = @ccall objc_msgSend(
            nsapplication::Ptr{Cvoid}, objc_sel("sharedApplication")::Ptr{Cvoid},
        )::Ptr{Cvoid}
        app == C_NULL && return nothing
        # NSApplicationActivationPolicyRegular = 0
        @ccall objc_msgSend(
            app::Ptr{Cvoid}, objc_sel("setActivationPolicy:")::Ptr{Cvoid}, 0::Clong,
        )::Bool
        @ccall objc_msgSend(
            app::Ptr{Cvoid}, objc_sel("activateIgnoringOtherApps:")::Ptr{Cvoid}, true::Bool,
        )::Cvoid
    catch error
        @warn "Could not promote to a macOS foreground app" exception=error
    end
    return nothing
end

"""
Give the keyboard focus back when the browser window closes. The process was made a regular macOS
app to show the window; without a window it would stay the active app, with nothing to click on.
No-op off macOS; never throws.
"""
function _leave_foreground_app()
    Sys.isapple() || return nothing
    try
        objc_class(name) = @ccall objc_getClass(name::Cstring)::Ptr{Cvoid}
        objc_sel(name) = @ccall sel_registerName(name::Cstring)::Ptr{Cvoid}
        nsapplication = objc_class("NSApplication")
        nsapplication == C_NULL && return nothing
        app = @ccall objc_msgSend(
            nsapplication::Ptr{Cvoid}, objc_sel("sharedApplication")::Ptr{Cvoid},
        )::Ptr{Cvoid}
        app == C_NULL && return nothing
        # Hiding activates the app that was in front before.
        @ccall objc_msgSend(
            app::Ptr{Cvoid}, objc_sel("hide:")::Ptr{Cvoid}, C_NULL::Ptr{Cvoid},
        )::Cvoid
        # NSApplicationActivationPolicyAccessory = 1: no Dock icon and no entry in Cmd-Tab.
        @ccall objc_msgSend(
            app::Ptr{Cvoid}, objc_sel("setActivationPolicy:")::Ptr{Cvoid}, 1::Clong,
        )::Bool
    catch error
        @warn "Could not give the keyboard focus back" exception=error
    end
    return nothing
end

# GLFW 3.4's public initial-position hints, not yet named by GLFW.jl.
# https://www.glfw.org/docs/3.4/window_guide.html#window_pos
const GLFW_POSITION_X = 0x0002000e
const GLFW_POSITION_Y = 0x0002000f
const GLFW_ANY_POSITION = typemin(Cint)

"""Set or clear GLFW's initial-position hints before a native window is created."""
function _set_browser_position_hints(position::Vector{Int}=Int[])::Nothing
    x, y = length(position) == 2 ? position : (GLFW_ANY_POSITION, GLFW_ANY_POSITION)
    GLFW.WindowHint(GLFW_POSITION_X, x)
    GLFW.WindowHint(GLFW_POSITION_Y, y)
    return nothing
end

function _set_browser_window_hints(window_start::Symbol)::Nothing
    if window_start == :normal
        GLFW.WindowHint(GLFW.FOCUSED, true)
        GLFW.WindowHint(GLFW.FOCUS_ON_SHOW, true)
    elseif window_start in (:background, :hidden)
        GLFW.WindowHint(GLFW.FOCUSED, false)
        GLFW.WindowHint(GLFW.FOCUS_ON_SHOW, false)
    else
        error("Unsupported browser window_start '$window_start'; use :normal, :background or :hidden")
    end
    return nothing
end

"""Render a small indeterminate loading spinner next to a short label."""
function _render_loading_spinner!(label::AbstractString)::Nothing
    radius = 8.0f0
    thickness = 2.4f0
    size = 24.0f0
    cursor = ig.GetCursorScreenPos()
    draw_list = ig.GetWindowDrawList()
    center = ig.ImVec2(cursor.x + size / 2, cursor.y + size / 2)
    phase = Float32(ig.GetTime() * 8.0)
    spokes = 12
    for index in 0:(spokes - 1)
        angle = phase + Float32(2π * index / spokes)
        alpha = 0.18f0 + 0.82f0 * Float32(index + 1) / Float32(spokes)
        inner = radius * 0.45f0
        outer = radius
        p1 = ig.ImVec2(center.x + cos(angle) * inner, center.y + sin(angle) * inner)
        p2 = ig.ImVec2(center.x + cos(angle) * outer, center.y + sin(angle) * outer)
        ig.AddLine(draw_list, p1, p2, ig.GetColorU32(ig.ImGuiCol_Text, alpha), thickness)
    end
    ig.Dummy((size, size))
    ig.SameLine(0.0f0, 10.0f0)
    ig.TextDisabled(label)
    return nothing
end

"""Render the minimal startup surface shown before expensive first-use GUI work finishes."""
function _render_startup_preparation!()::Nothing
    center = ig.ImGuiViewport_GetCenter(ig.GetMainViewport())
    flags = ig.ImGuiWindowFlags_NoDecoration | ig.ImGuiWindowFlags_NoMove |
            ig.ImGuiWindowFlags_NoSavedSettings | ig.ImGuiWindowFlags_AlwaysAutoResize |
            ig.ImGuiWindowFlags_NoInputs
    ig.SetNextWindowPos(center, ig.ImGuiCond_Always, (0.5, 0.5))
    if ig.Begin("###browser_startup_preparation", C_NULL, flags)
        _render_loading_spinner!("Loading")
    end
    ig.End()
    return nothing
end

"""Shown while the table `items` of the workspace is closed: during a rebuild, and after closing."""
function _render_workspace_updating!()::Nothing
    center = ig.ImGuiViewport_GetCenter(ig.GetMainViewport())
    flags = ig.ImGuiWindowFlags_NoDecoration | ig.ImGuiWindowFlags_NoMove |
            ig.ImGuiWindowFlags_NoSavedSettings | ig.ImGuiWindowFlags_AlwaysAutoResize |
            ig.ImGuiWindowFlags_NoInputs
    ig.SetNextWindowPos(center, ig.ImGuiCond_Always, (0.5, 0.5))
    if ig.Begin("###workspace_updating", C_NULL, flags)
        ig.TextUnformatted("Updating workspace…")
    end
    ig.End()
    return nothing
end

"""
Give Julia's I/O event loop (libuv) its own thread, once per process.

The render loop of the browser is pinned to thread 1, where Julia also runs its I/O event loop
([JuliaLang/julia#50643](https://github.com/JuliaLang/julia/issues/50643)). A busy render loop
then delays I/O completions, and the workers that read source files slow down. Call
`DEDICATED_IO_THREAD()` before the render loop starts.
"""
const DEDICATED_IO_THREAD = Base.OncePerProcess{Nothing}() do
    Base.Experimental.make_io_thread()
    nothing
end

"""
Run the browser render loop for a prepared state. With `wait=false` the loop runs as a background
task pinned to thread 1 (required for GLFW) and the call returns that task, leaving the REPL live.
"""
function _run_browser(
    state::BrowserState,
    ctx;
    engine,
    spawn,
    wait::Bool,
    exit_after_frames::Union{Nothing,Int}=nothing,
    window_start::Symbol=:normal,
)
    exit_after_frames === nothing || exit_after_frames > 0 ||
        error("exit_after_frames must be positive when provided; got $exit_after_frames")
    DEDICATED_IO_THREAD()
    view = _load_project_view(state.workspace)
    state.saved_project_view = view
    window_options = length(view.window_size) == 2 && all(>(0), view.window_size) ?
        (; window_size=Tuple(view.window_size)) : (;)
    _set_browser_window_hints(window_start)
    _set_browser_position_hints(view.window_position)
    # A GLFW error while the browser runs, such as a paste when the clipboard holds no text, is a
    # warning: GLFW.jl's own handler throws it out of the frame and stops the drawing.
    GLFW.SetErrorCallback(error -> @warn "GLFW: $(error.description)")
    first_frame       = Ref(true)
    startup_presented = Ref(false)
    full_frame_submitted = Ref(false)
    return ig.render(
        ctx;
        engine,
        spawn,
        wait,
        window_options...,
        window_title="Data Browser",
        opengl_version=v"3.3",
        wait_events=false,
        on_exit=() -> begin
            # The workspace keeps running after the browser closes.
            @atomic state.workspace.code_updates_active = true
            # An instance may hold a figure that must be released before the window goes. The
            # windows stay in the list, so that they are saved and open again next time, and their
            # visualizers stay in the workspace.
            # Finish handovers while the graphics context and workspace are still available.
            for window in Iterators.flatten((state.windows, state.closing_windows))
                # `wait` is this function's keyword here.
                preparing(window) && Base.wait(window.preparation.task)
                _finish_preparation!(window)
            end
            _finish_closed_windows!(state)
            _discard_window_previews!()
            foreach(state.windows) do window
                _close_visualizers!(window)
            end
            _shutdown_extensions!(state)
            _shutdown_implot_context!(state)
            _save_project_view_if_changed!(state; every=0)
            GLFW.HideWindow(ig.current_window())
            window_start == :normal && _leave_foreground_app()
            # macOS takes the window off the screen while the process handles window events, and
            # nothing handles them after the loop ends.
            for _ in 1:20
                GLFW.PollEvents()
                sleep(0.01)
            end
            @debug sprint(show, MAIN_TIMER)
        end,
    ) do
        _window_close_requested(state) && return :imgui_exit_loop
        @atomic state.workspace.code_updates_active =
            GLFW.GetWindowAttrib(ig.current_window(), GLFW.FOCUSED) != 0
        state.performance.frame += 1
        # The backend renders and swaps the previous frame before calling us again.
        # Discard startup timings once the first full frame has been presented, or on request.
        # No timed section is open at frame top, so resetting the section stack is safe.
        if state.performance.reset_main_timer || (full_frame_submitted[] && !state.performance.ready)
            TimerOutputs.reset_timer!(MAIN_TIMER)
            state.performance.reset_main_timer = false
        end
        state.performance.ready |= full_frame_submitted[]
        workspace = state.workspace
        # A rebuild closes the table `items`, and replaces it last.
        if workspace.items.closed
            _render_workspace_updating!()
            return nothing
        end
        # The parts of the frame are dynamic calls (`@invokelatest`). A package that loads while
        # the browser is open can invalidate the compiled code of some parts: the next frame then
        # compiles those parts again, not the whole frame.
        @invokelatest _check_source_identity!(state, workspace)
        @invokelatest _check_cache_error!(state, workspace)
        # Reveal a selection made through the workspace, from the REPL or by an action: one
        # that differs from the selection that the browser revealed or made itself.
        selected = (@atomic workspace.shared).selection
        if selected !== state.selection
            selected == state.selection || @invokelatest _reveal_selected_items!(state)
            state.selection = selected
        end
        exit_after_frames !== nothing && state.performance.frame >= exit_after_frames &&
            return :imgui_exit_loop
        if first_frame[]
            # The main window has been created. Do not give its placement hints to other
            # windows created by visualizers or by ImGui's multi-viewport backend.
            _set_browser_position_hints()
            state.performance.gl_info = _gl_info()
            window_start == :normal && _promote_to_foreground_app()
            # The backend always creates the window visible.
            window_start == :hidden && GLFW.HideWindow(ig.current_window())
            first_frame[] = false
        end
        # Extensions of packages loaded while the browser is open, such as its plot windows.
        @invokelatest _add_new_extensions!(state)
        if !full_frame_submitted[] && !(@invokelatest _extensions_ready(state))
            # Present the preparation surface for one frame before running any blocking
            # extension warmup, so the window is never blank during the expensive part.
            _render_startup_preparation!()
            if startup_presented[]
                @timed "extension_warmup" begin
                    for ext in state.extensions
                        @invokelatest(is_ready(ext, state)) || @invokelatest(warmup!(ext, state))
                    end
                end
            else
                startup_presented[] = true
            end
            return nothing
        end
        @timed "frame_ui" begin
            # The toolbar comes first, so that the windows dock in the room below it.
            @timed "toolbar" begin
                @invokelatest render_toolbar!(state)
            end
            ig.DockSpaceOverViewport(0, ig.GetMainViewport())
            @timed "selection_window" begin
                @invokelatest render_selection_window(state)
            end
            @timed "info" begin
                @invokelatest render_info_window(state)
            end
            @timed "windows" begin
                @invokelatest render_windows!(state)
            end
            @timed "extensions" begin
                for ext in state.extensions
                    # An extension added after the startup screen prepares during the frames.
                    @invokelatest(is_ready(ext, state)) || @invokelatest(warmup!(ext, state))
                    @invokelatest draw!(ext, state)
                end
            end
            @timed "perf_window" begin
                @invokelatest render_perf_window(state)
            end
            @timed "debug_tools" begin
                @invokelatest render_debug_tools!(state)
            end
            @timed "persist_view" begin
                @invokelatest _save_project_view_if_changed!(state)
            end
            @timed "modals" begin
                @invokelatest render_cache_rebuild_modal(state)
            end
        end
        full_frame_submitted[] = true
    end
end

"""
Open the browser on an already-opened workspace (see `open_workspace`). By default, blocks
until the window closes in non-interactive sessions (`julia script.jl`) and returns immediately
in the REPL so it stays interactive.

With `wait=false`, returns a [`BrowserSession`](@ref) (`task` + `state`). Use
[`wait_browser_ready`](@ref) to wait until extension initialization is complete and the first
full browser frame has been presented. Use [`close_browser!`](@ref) to exit the loop cleanly.

Panel positions, docking and table widths use ImGui’s `imgui.ini` in the current working
directory. The native window position and size are saved with the view of the project in
`databrowser.toml`, in the folder of the Julia environment that was active when the workspace
opened, and used when creating the window, before the first ImGui frame.

Closing the window closes the browser only. The workspace stays open and keeps processing items,
and `open_browser` can show it again. Use `close_workspace!` to close the workspace.

Automatic code updates pause while the main browser window is inactive and resume when it gains
keyboard focus. Closing the browser resumes the workspace's automatic code updates.

Start Julia with `--threads=auto,1`: thread 1 runs the UI and the default pool prepares values.

`window_start` says how the window appears: `:normal` shows it and gives it the keyboard focus,
`:background` shows it without the focus, and `:hidden` does not show it.

After `using DataBrowser`, the browser loads GLMakie on a worker thread after its first frame, when
it is in the active environment and not loaded yet. The plot windows appear when it has loaded,
after a few seconds; saved plot windows show "Loading" until then.
"""
function open_browser(
    workspace::Workspace.Workspace;
    engine::Any=nothing,
    spawn::Int=1,
    wait::Bool=!isinteractive(),
    window_start::Symbol=:normal,
)
    workspace.closed && error("The workspace is closed. Open it again with `open_workspace`.")
    Threads.threadpool(1) === :interactive && Threads.threadpoolsize(:default) > 0 ||
        error("The browser needs a UI thread and background workers. Start Julia with --threads=auto,1.")
    # The first opening logs a line, so that a script run from a shell shows that it goes on until
    # the window appears.
    @info "Opening browser" maxlog=1
    state = BrowserState(; workspace)
    state.extensions = _instantiate_extensions()
    for ext in state.extensions
        init!(ext, state)
    end
    ctx, fonts = _init_browser_context!()
    @atomic workspace.code_updates_active = false
    result = try
        ScopedValues.with(_CURRENT_FONTS => fonts, _WINDOW_PREVIEWS => WindowPreviewCache()) do
            _run_browser(state, ctx; engine, spawn, wait, window_start=window_start)
        end
    catch
        @atomic workspace.code_updates_active = true
        rethrow()
    end
    return wait ? result : BrowserSession(result::Task, state)
end

"""Ask a non-blocking browser session to exit and wait until the render task finishes."""
function close_browser!(session::BrowserSession; timeout_s::Real=60.0)::Nothing
    session.state.exit_requested = true
    deadline = time() + Float64(timeout_s)
    while !istaskdone(session.task) && time() < deadline
        sleep(0.05)
    end
    istaskdone(session.task) || @warn "close_browser!: render task still running after $(timeout_s)s"
    return nothing
end
