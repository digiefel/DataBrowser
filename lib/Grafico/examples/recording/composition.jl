using Grafico, CairoMakie, WGLMakie

time = range(0, 8π; length = 600)
signal = data((time = time, amplitude = sin.(time) .* exp.(-time ./ 20))) *
    mapping(:time => "Time", :amplitude => "Amplitude") * visual(Lines)

# The same ordinary chart can be drawn alone, placed in a diagram, or animated.
window = Observable(extrema(time))
placement = Observable(T(0, 0) * U(1))
detail = mark(signal + coord(x = (limits = window,)))
fig = figure(signal + placement * detail; figure_kw = (size = (1000, 600),))

# The detail stays zoomed when it becomes an inset. Native text remains readable
# as Makie lays out the smaller chart. Change either duration or either target.
story = Grafico.plan(sequence(
    hold(),
    to(window => (2π, 4π); duration = 1.2),
    hold(),
    to(placement => T(0.54, 0.55) * U(0.42, 0.40); duration = 1.4),
    hold(),
))

output = joinpath(@__DIR__, "output")
mkpath(output)
record(fig, joinpath(output, "composition.html"), story;
    still = joinpath(output, "composition.svg"))
