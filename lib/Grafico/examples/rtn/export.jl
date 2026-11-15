using WGLMakie, CairoMakie
include("rtn.jl")

output = joinpath(@__DIR__, "output")
mkpath(output)
record(fig, joinpath(output, "rtn.html"), playback;
       still = joinpath(output, "rtn.svg"))
