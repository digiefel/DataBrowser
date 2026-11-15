module GraficoWGLMakieExt

using Grafico, Makie, WGLMakie
import Bonito

include("recording/values.jl")
include("recording/capture.jl")
include("recording/export.jl")

function record_html(figure, path, planned; framerate = 60)
    recording = capture(figure, planned; fps = framerate)
    export_html(path, recording)
end

end
