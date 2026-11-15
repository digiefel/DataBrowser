module GraficoWGLMakieExt

using Grafico, Makie, WGLMakie
import Bonito, Logging

include("recording/logger.jl")
include("recording/values.jl")
include("recording/capture.jl")
include("recording/export.jl")

function record_html(figure, path, planned; framerate = 60)
    recording = Logging.with_logger(CaptureLogger(Logging.current_logger())) do
        capture(figure, planned; fps = framerate)
    end
    export_html(path, recording)
end

end
