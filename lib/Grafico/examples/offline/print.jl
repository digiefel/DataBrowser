module GraficoOfflinePrint

using CairoMakie, Grafico
import WGLMakie

include("author.jl")
output = joinpath(@__DIR__, "output")
mkpath(output)

CairoMakie.activate!()
try
    Grafico.seek!(playback, Grafico.duration(playback))
    fig = figure(cloud; figure_kw = (size = (800, 600),))
    save(joinpath(output, "final.svg"), fig)
    save(joinpath(output, "final.pdf"), fig)
    println("GRAFICO_VECTOR_STATE_READY time=", playback.time[])
finally
    WGLMakie.activate!(framerate = 60, resize_to = :parent)
end

end
