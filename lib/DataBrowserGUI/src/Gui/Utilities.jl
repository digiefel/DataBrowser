import CImGui as ig

"""Draw a grey question mark that shows `description` while the mouse is over it."""
function _helpmarker(description::String)::Nothing
    ig.TextDisabled("(?)")
    if ig.BeginItemTooltip()
        ig.PushTextWrapPos(ig.GetFontSize() * 35.0)
        ig.TextUnformatted(description)
        ig.PopTextWrapPos()
        ig.EndTooltip()
    end
    return nothing
end

"""
Run `f`, which draws with ImGui, and return why it failed, or "" when it did not. After a failure
ImGui is back in the state it had before `f`, so the drawing goes on as if `f` had stopped there.
The message starts with `context`. `f` runs in every frame and fails again in each one, so the error
is logged only when the message differs from `last`, the message of the frame before.
"""
function guarded_draw(f, context::String, last::String)::String
    state = Ref{ig.lib.ImGuiErrorRecoveryState}()
    ig.lib.igErrorRecoveryStoreState(state)
    try
        f()
        return ""
    catch err
        backtrace = catch_backtrace()
        ## Without this, ImGui stops at an assertion, logs, and shows a tooltip, for each call `f`
        ## left without its end, such as a `Begin` without `End`.
        io = ig.GetIO()
        options = (io.ConfigErrorRecoveryEnableAssert, io.ConfigErrorRecoveryEnableDebugLog,
            io.ConfigErrorRecoveryEnableTooltip)
        before = unsafe_load.(options)
        unsafe_store!.(options, false)
        ig.lib.igErrorRecoveryTryToRecoverState(state)
        unsafe_store!.(options, before)
        message = context * "\n" * DataBrowserAPI.error_summary(err, backtrace)
        message == last || DataBrowserAPI.report_error(context, err, backtrace)
        return message
    end
end
