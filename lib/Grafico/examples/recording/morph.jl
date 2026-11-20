using Grafico, CairoMakie, WGLMakie

x = collect(range(-2, 2; length = 121))
variables = mapping(:x => "Position", :y => "Reading")

first_plot = data((; x, y = sin.(3x))) * variables *
    visual(Lines; color = Cycled(1))
next_plot = data((; x, y = .5cos.(5x))) * variables *
    visual(Lines; color = Cycled(4), linewidth = 5)
points = data((; x, y = cos.(3x))) * variables *
    visual(Scatter; color = Cycled(2))

fig = figure(first_plot; figure_kw = (size = (1100, 550),))

# Change ordinary plots. Existing panels morph and move into place;
# new panels grow into the space opened by their neighbours.
playback = Grafico.plan(sequence(
    hold(),
    to(fig => next_plot; duration = 2),
    hold(),
    to(fig => next_plot | points; duration = 1.4),
    hold(),
))

output = joinpath(@__DIR__, "output")
mkpath(output)
record(fig, joinpath(output, "morph.html"), playback;
       still = joinpath(output, "morph.svg"))
