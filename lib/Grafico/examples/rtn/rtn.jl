using CairoMakie, Grafico, Random, Statistics

# This file is ordinary Julia. The helper below only generates synthetic data;
# replace these two lines with the data loading used by a real experiment.
include("data.jl")
trace = synthetic_trace()

sample_count = length(trace.t)
current_limits = (2.615, 2.725)

# Playback and mouse controls write to these same Observables.
samples_shown = Observable(1.0)
pairs_shown = Observable(0.0)
subtraction = Observable(0.0)
model_opacity = Observable(0.0)
time_window = Observable(extrema(trace.t))
lag = Observable(1)

# Subtract a fraction of the known switching contribution, retaining the mean.
residual = lift(subtraction) do fraction
    trace.raw .- fraction .* (trace.rtn .- trace.μ)
end
samples = lift(samples_shown) do shown
    count = clamp(floor(Int, shown), 1, sample_count)
    (current = trace.raw[1:count],)
end

# Each lag-plot dot takes its x and y from two samples of the same signal.
function lag_pairs(signal, shown, delay)
    lift(signal, shown, delay) do current, shown, delay
        count = clamp(floor(Int, shown), 0, length(current) - delay)
        (
            now = current[1:count],
            later = current[1 + delay:count + delay],
        )
    end
end

# Labels describe the mapped variables. Palette indices identify the signals;
# fonts, line widths, grids, backgrounds, and the palette itself stay Makie's.
time_current = mapping(:time => "Time / s", :current => "Current / µA")
raw_trace = data((time = trace.t, current = trace.raw)) *
    time_current * visual(Lines; color = Cycled(1))
switching_trace = data((time = trace.t, current = trace.rtn)) *
    time_current * visual(Lines; color = Cycled(2), alpha = model_opacity)

# coord changes the displayed window, without filtering data used by analyses.
trace_coordinates = coord(
    x = (limits = time_window,),
    y = (limits = current_limits,),
)
raw_panel = raw_trace + switching_trace + trace_coordinates
residual_panel = data((time = trace.t, current = residual)) *
    time_current * visual(Lines; color = Cycled(4)) + trace_coordinates

histogram_panel = data(samples) * mapping(:current => "Current / µA") *
    Grafico.histogram(
        bins = range(current_limits...; length = 43),
        direction = :x,
    ) * visual(BarPlot; color = Cycled(1)) +
    scales(x = (label = "Samples",)) + coord(
        x = (limits = (0, 200), reversed = true),
        y = (limits = current_limits,),
    )

lag_marks = mapping(:now => "I(t) / µA", :later => "I(t + Δt) / µA") *
    visual(Scatter; color = Cycled(2))
lag_coordinates = coord(
    x = (limits = current_limits,),
    y = (limits = current_limits,),
    aspect = 1,
)
raw_lag_panel = data(lag_pairs(Observable(trace.raw), pairs_shown, lag)) *
    lag_marks + lag_coordinates
residual_lag_panel = data(lag_pairs(residual, pairs_shown, lag)) *
    lag_marks + lag_coordinates

# An empty slot reserves space. The story fills it with an ordinary GoG plot.
histogram_view = Observable{Any}(nothing)
residual_view = Observable{Any}(nothing)
raw_lag_view = Observable{Any}(nothing)
residual_lag_view = Observable{Any}(nothing)

fig = figure(
    [histogram_view raw_panel raw_lag_view;
     nothing residual_view residual_lag_view];
    figure_kw = (size = (1800, 950),),
    layout = (
        colgaps = 0,
        rowgaps = 0,
        colsizes = [Auto(1), Auto(3), Aspect(1, 1)],
        linkxaxes = :colwise,
        linkyaxes = :rowwise,
    ),
)

# Each value describes a motion. The plan can be sampled in either direction.
motion = sequence(
    hold(),
    to(time_window => trace.zoom; duration = 1.4),
    to(model_opacity => 1.0),
    hold(),
    to(time_window => extrema(trace.t); duration = 1.4),

    to(histogram_view => histogram_panel; duration = 0),
    to(samples_shown => sample_count; duration = 6, ease = identity),
    hold(),

    to(residual_view => residual_panel; duration = 0),
    to(subtraction => 1.0; duration = 2.5),
    hold(),

    to(raw_lag_view => raw_lag_panel, residual_lag_view => residual_lag_panel; duration = 0),
    to(pairs_shown => sample_count - 1; duration = 6, ease = identity),
    hold(),
)
playback = Grafico.plan(motion)
