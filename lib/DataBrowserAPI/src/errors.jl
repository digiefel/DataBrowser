"""Format an exception with short frame names, stopping before DataBrowser's callers."""
function error_summary(error, backtrace)
    frames = Base.StackTraces.StackFrame[]
    for frame in stacktrace(backtrace)
        frame.from_c && continue
        internal = occursin(r"/DataBrowser[^/]+/(src|ext)/", string(frame.file))
        push!(frames, Base.StackTraces.StackFrame(frame.func, frame.file, frame.line))
        internal && break
    end
    return sprint() do io
        showerror(IOContext(io, :limit => true), error)
        Base.show_backtrace(io, frames)
    end
end

"""Log a concise error and return its summary and full details for a view to retain."""
function report_error(context, error, backtrace; details="")
    summary = context * "\n" * error_summary(error, backtrace)
    full = context * "\n" * sprint(showerror, error, backtrace) *
        (isempty(details) ? "" : "\n\n" * details)
    @error summary
    @debug context exception=(error, backtrace) details
    return summary, full
end

"""Describe the source by its type and display label without exposing its internal state."""
source_description(source::AbstractDataSource) =
    "$(nameof(typeof(source)))($(repr(label(source))))"
