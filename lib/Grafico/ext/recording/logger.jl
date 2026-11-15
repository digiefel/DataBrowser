# The native headless path deliberately requests a complete glyph payload.
# WGLMakie reports that supported fallback every time an axis tick changes.
# Keep all other backend and author-code messages on the caller's logger.
struct CaptureLogger{L<:Logging.AbstractLogger} <: Logging.AbstractLogger
    parent::L
end

Logging.min_enabled_level(logger::CaptureLogger) = Logging.min_enabled_level(logger.parent)
Logging.shouldlog(logger::CaptureLogger, args...) = Logging.shouldlog(logger.parent, args...)
Logging.catch_exceptions(logger::CaptureLogger) = Logging.catch_exceptions(logger.parent)

function Logging.handle_message(logger::CaptureLogger, level, message, source, group, id, file, line; kwargs...)
    if source === WGLMakie && level == Logging.Warn &&
            message == "No session found, returning empty atlas tracker"
        return
    end
    Logging.handle_message(logger.parent, level, message, source, group, id, file, line; kwargs...)
end
