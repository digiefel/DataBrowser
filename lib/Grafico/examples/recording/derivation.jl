using Grafico, CairoMakie, WGLMakie

# This dataset is unrelated to the RTN example.
time = collect(range(0, 1; length = 30))
reading = 2 .+ .35sin.(time .* 7π) .+ .04cos.(time .* 39π)
readings = data((; time, reading))

signal = readings * mapping(:time => "Time", :reading => "Reading") * visual(Lines)
distribution = readings * mapping(:reading => "Reading") *
    Grafico.histogram(direction = :x)
pairs = data((now = @view(reading[1:end-3]), later = @view(reading[4:end]))) *
    mapping(:now => "Earlier reading", :later => "Later reading") * visual(Scatter)

histogram_view = Observable{Any}(nothing)
pair_view = Observable{Any}(nothing)
fig = figure([histogram_view signal pair_view]; figure_kw = (size = (1400, 550),))

# The same `to` moves attributes and explains observations. Pace and routes are
# optional: duration = 16 slows the second explanation; path = (a, b, u) ->
# (1-u)*a + u*b would replace the default curved routes with straight ones.
playback = Grafico.plan(sequence(
    hold(),
    to(histogram_view => distribution; from = signal),
    hold(),
    to(pair_view => pairs; from = signal, duration = 16),
    hold(),
))

output = joinpath(@__DIR__, "output")
mkpath(output)
record(fig, joinpath(output, "derivation.html"), playback;
       still = joinpath(output, "derivation.svg"))
