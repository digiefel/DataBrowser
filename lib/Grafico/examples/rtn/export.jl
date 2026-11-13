using CairoMakie, Base64
include("rtn.jl")

output = joinpath(@__DIR__, "output")
mkpath(output)
CairoMakie.activate!()
Grafico.seek!(playback, Grafico.duration(playback))
save(joinpath(output, "rtn.svg"), fig)
save(joinpath(output, "rtn.pdf"), fig)

record(fig, joinpath(output, "rtn.mp4"),
       range(0, Grafico.duration(playback); step = 1 / 30); framerate = 30) do time
    Grafico.seek!(playback, time)
end
video = base64encode(read(joinpath(output, "rtn.mp4")))
write(joinpath(output, "rtn.html"), """
<!doctype html><meta charset="utf-8"><title>Grafico RTN recording</title>
<style>body{margin:0}video{width:100%;height:100vh}</style>
<video controls src="data:video/mp4;base64,$video"></video>
""")
