using Grafico, CairoMakie, WGLMakie

x = collect(range(-2, 2; length = 121))
variables = mapping(:x => "Position", :y => "Reading")

first_plot = data((; x, y = sin.(3x))) * variables *
    visual(Lines; color = Cycled(1))
next_plot = data((; x, y = .5cos.(5x))) * variables *
    visual(Lines; color = Cycled(4), linewidth = 5)
points = data((; x, y = cos.(3x))) * variables *
    visual(Scatter; color = Cycled(2))

view = Observable{Any}(first_plot)
fig = figure(view; figure_kw = (size = (1100, 550),))

# Change ordinary plots. The default morph resolves data, styling, and limits;
# a changed panel layout fades complete charts, including their decorations.
playback = Grafico.plan(sequence(
    hold(),
    to(view => next_plot; duration = 2),
    hold(),
    to(view => next_plot | points; duration = 1.4),
    hold(),
))

output = joinpath(@__DIR__, "output")
mkpath(output)
record(fig, joinpath(output, "morph.html"), playback;
       still = joinpath(output, "morph.svg"))
