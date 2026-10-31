# The browser follows the workspace: a change made through the workspace, such as `select!`, shows
# in the browser without an action of its own. GUI-only actions take a session.

"""
The timings of the frames the browser drew, as the live `TimerOutput`: every TimerOutputs function
works on it, such as `print_timer`. Only the render task writes to it; read it while the browser is
idle for consistent numbers.
"""
gui_timings(session::BrowserSession) = MAIN_TIMER

"""
Clear the timings of [`gui_timings`](@ref). The browser clears them at the start of its next frame,
where no timed section is open; nothing happens if the browser is not running.
"""
function reset_timings!(session::BrowserSession)::Nothing
    session.state.performance.reset_main_timer = true
    return nothing
end

"""
    wait_browser_ready(session; timeout_s=120) -> session

Wait until the browser has drawn its full window once, after every extension is ready; the startup
screen does not count. This does not wait for the background work of the workspace. Rethrow the
error of the render task; throw if the browser closes or `timeout_s` seconds pass first.
"""
function wait_browser_ready(session::BrowserSession; timeout_s::Real=120)
    deadline = time() + timeout_s
    while !session.state.performance.ready
        if istaskdone(session.task)
            fetch(session.task)
            error("Browser closed before becoming ready")
        end
        time() < deadline || error("Browser did not become ready within $(timeout_s) seconds")
        sleep(0.01)
    end
    return session
end
