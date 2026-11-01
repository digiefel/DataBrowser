using Statistics: mean, median, std

"""
A vector shown as an index plot, a sideways histogram, a color strip and an empirical cumulative
distribution (ECDF). The index ranges of the trace and strip are linked; the value ranges of the
trace, histogram and ECDF are linked. Summary statistics and a horizontally scrolling numeric
strip appear above the plots. Frequency Analysis switches to FFT amplitude, PSD and autocorrelation.
Distributions and statistics use only finite values; standard deviation uses n - 1.
"""
Base.@kwdef mutable struct VectorView <: AbstractVisualizer
    overlay::Vector{VectorView} = VectorView[]
    overlay_ids::Vector{String} = String[]
    overlay_labels::Vector{String} = String[]
    overlay_active::String = ""
    indices::Vector{Float64} = Float64[]
    values::Vector{Float64} = Float64[]
    finite::Vector{Float64} = Float64[]
    value_labels::Vector{String} = String[]
    input_message::String = ""
    numeric_reset::Bool = true
    numeric_characters::Int = 1
    statistics::Vector{Pair{String,String}} = Pair{String,String}[]
    cdf_values::Vector{Float64} = Float64[]
    cdf_fractions::Vector{Float64} = Float64[]
    smooth_values::Vector{Float64} = Float64[]
    smooth_density::Vector{Float64} = Float64[]
    smooth_counts::Vector{Float64} = Float64[]
    color_limits::Tuple{Float64,Float64} = (0.0, 1.0)
    index_min::Ref{Float64} = Ref(0.0)
    index_max::Ref{Float64} = Ref(1.0)
    value_min::Ref{Float64} = Ref(0.0)
    value_max::Ref{Float64} = Ref(1.0)
    distribution_ratios::Vector{Float32} = Float32[2, 0.5, 0.5]
    distribution_geometry::Tuple{Float32,Float32} = (NaN32, NaN32)
    signal::Bool = false
    log_frequency::Bool = false
    log_amplitude::Bool = false
    frequency_was_log::Bool = false
    amplitude_was_log::Bool = false
    sample_spacing::Float64 = 1.0
    remove_mean::Bool = true
    signal_data::VectorSignal = VectorSignal()
    signal_fit::Bool = true
    frequency_min::Ref{Float64} = Ref(0.0)
    frequency_max::Ref{Float64} = Ref(0.5)
    bins::Int = 64
    density::Bool = false
    smooth::Bool = true
    markers::Bool = false
    histogram_settings::Tuple{Int,Bool} = (0, false)
end

label(::VectorView)::String = "Vector"
DataBrowserAPI.initial_size(::VectorView) = (900, 360)

settings(view::VectorView) = (
    signal=Setting("Frequency Analysis"),
    log_frequency=Setting("Log frequency"; prepare=false, visible=false),
    log_amplitude=Setting("Log amplitude"; prepare=false, visible=false),
    sample_spacing=Setting("Sample spacing"; visible=view.signal),
    remove_mean=Setting("Remove mean"; visible=view.signal),
    bins=Setting("Bins"; prepare=false, visible=!view.signal),
    density=Setting("Density"; prepare=false, visible=!view.signal),
    smooth=Setting("Smooth distribution"; prepare=false, visible=!view.signal),
    markers=Setting("Markers"; prepare=false, visible=!view.signal),
)

"""Compact axis scale controls and markers for Frequency Analysis."""
function DataBrowserAPI.draw_header!(view::VectorView, ctx)::Nothing
    if !isempty(view.overlay)
        i = something(findfirst(==(view.overlay_active), view.overlay_ids), 1)
        if ig.BeginCombo("##overlay-active", view.overlay_labels[i], ig.ImGuiComboFlags_WidthFitPreview)
            for j in eachindex(view.overlay)
                ig.Selectable("$(view.overlay_labels[j])###$(view.overlay_ids[j])", i == j) &&
                    (view.overlay_active = view.overlay_ids[j])
            end
            ig.EndCombo()
        end
        ig.SetItemTooltip("Item shown in the numeric strip and statistics. All items remain plotted.")
        view.signal && ig.SameLine()
    end
    view.signal || return nothing
    if ig.SmallButton(view.log_frequency ? "f: Log" : "f: Linear")
        view.log_frequency = !view.log_frequency
    end
    ig.SetItemTooltip("Frequency axis: switch between linear and logarithmic. Applies to FFT and PSD.")
    ig.SameLine()
    if ig.SmallButton(view.log_amplitude ? "A: Log" : "A: Linear")
        view.log_amplitude = !view.log_amplitude
    end
    ig.SetItemTooltip("Amplitude axis: switch between linear and logarithmic. Applies to FFT amplitude and PSD power.")
    ig.SameLine()
    markers = Ref(view.markers)
    ig.Checkbox("Markers", markers) && (view.markers = markers[])
    return nothing
end

function prepare!(view::VectorView, values::Numbers, ctx)::Nothing
    empty!(view.overlay)
    empty!(view.overlay_ids)
    empty!(view.overlay_labels)
    view.input_message = ""
    return prepare_vector!(view, values, ctx)
end

"""Unwrap the single numeric column passed on by a Table window."""
prepare!(view::VectorView, column::NamedTuple{<:Any,<:Tuple{Any}}, ctx) =
    prepare!(view, only(column), ctx)

"""Overlay each selected item's vector, retaining independent statistics and spectra."""
function prepare!(view::VectorView, selection::Selection, ctx)::Nothing
    if length(selection) <= 1
        return prepare!(view, isempty(selection) ? Float64[] : only(selection.data), ctx)
    end
    values = collect(selection.data)
    settings_values = (; (name => getproperty(view, name) for name in keys(settings(view)))...)
    prepared = VectorView[]
    for value in values
        child = VectorView(; settings_values...)
        prepare!(child, value, ctx)
        push!(prepared, child)
    end
    with_values = filter(child -> !isempty(child.finite), prepared)
    if !isempty(with_values)
        view.value_min[] = minimum(child -> child.value_min[], with_values)
        view.value_max[] = maximum(child -> child.value_max[], with_values)
        view.index_min[] = minimum(child -> child.index_min[], with_values)
        view.index_max[] = maximum(child -> child.index_max[], with_values)
    end
    view.overlay = prepared
    reset_overlay_frequency!(view)
    view.overlay_ids = String.(selection.id)
    view.overlay_labels = String.(selection.label)
    view.overlay_active in view.overlay_ids || (view.overlay_active = first(view.overlay_ids))
    view.input_message = ""
    view.signal_fit = true
    return nothing
end

function prepare_vector!(view::VectorView, values::Numbers, ctx)::Nothing
    # Copy in iteration order: an AbstractVector need not start at index 1 or own its storage.
    view.indices = Float64[i for i in eachindex(values)]
    view.value_labels = [sprint(show, v; context=:compact => true) for v in values]
    view.numeric_reset = true
    view.values = Float64[isfinite(v) ? v : NaN for v in values]
    # A finite Real can overflow when converted to Float64.
    map!(v -> isfinite(v) ? v : NaN, view.values, view.values)
    view.numeric_characters = maximum(v -> length(@sprintf("%.4g", v)), view.values; init=1)
    view.finite = filter(isfinite, view.values)
    view.signal_data = view.signal ? vector_signal(view.values, view.sample_spacing; remove_mean=view.remove_mean) : VectorSignal()
    view.signal_fit = true
    reset_vector_frequency!(view)
    sorted = sort(view.finite)
    n = length(sorted)
    # Extra endpoints extend the ECDF's zero and one tails to the visible value range.
    view.cdf_values = n == 0 ? Float64[] : [first(sorted); sorted; last(sorted)]
    view.cdf_fractions = n == 0 ? Float64[] : [0.0; (1:n) ./ n; 1.0]
    view.smooth_values, view.smooth_density = vector_density(view.finite)
    view.smooth_counts = similar(view.smooth_density)
    view.histogram_settings = (0, false)
    view.statistics = ["Length" => string(length(values))]
    n != length(values) && push!(view.statistics, "Finite" => string(n))
    if n > 0
        lo, hi = extrema(sorted)
        deviation = n > 1 ? @sprintf("%.6g", std(view.finite)) : "—"
        append!(view.statistics, ["Min" => @sprintf("%.6g", lo), "Max" => @sprintf("%.6g", hi),
            "Mean" => @sprintf("%.6g", mean(view.finite)), "Median" => @sprintf("%.6g", median(sorted)),
            "Std. dev." => deviation])
        padding = lo == hi ? max(abs(lo) * 0.05, 0.5) : (hi / 2 - lo / 2) * 0.1
        view.color_limits = lo == hi ? (lo - padding, hi + padding) : (lo, hi)
        view.value_min[], view.value_max[] = lo - padding, hi + padding
        view.index_min[], view.index_max[] = first(view.indices) - 0.5, last(view.indices) + 0.5
    else
        append!(view.statistics, [name => "—" for name in ("Min", "Max", "Mean", "Median", "Std. dev.")])
    end
    return nothing
end

const VECTOR_PLOT_FLAGS = ig.lib.ImPlotFlags_NoTitle | ig.lib.ImPlotFlags_NoLegend

function draw!(view::VectorView, ctx)::Nothing
    view.bins = clamp(view.bins, 1, 4096)
    isempty(view.overlay) || return draw_vector_overlay!(view, ctx)
    if !isempty(view.input_message)
        ig.TextWrapped(view.input_message)
        return nothing
    end
    n, finite = length(view.values), length(view.finite)
    n > 0 && draw_vector_numbers!(view)
    draw_vector_statistics!(view)
    if view.signal
        GC.@preserve view draw_vector_signal!(view, ctx)
    elseif finite == 0
        ig.TextUnformatted(n == 0 ? "Empty vector" : "No finite values to plot")
    else
        GC.@preserve view draw_vector_plots!(view, ctx)
    end
    return nothing
end

"""Draw aligned statistic labels and values directly below the numeric strip."""
function draw_vector_statistics!(view::VectorView)::Nothing
    isempty(view.statistics) && return nothing
    flags = ig.ImGuiTableFlags_SizingStretchSame | ig.ImGuiTableFlags_NoSavedSettings
    ig.PushStyleVar(ig.ImGuiStyleVar_ItemSpacing, ig.ImVec2(4, 1))
    try
        if ig.BeginTable("##vector-statistics", length(view.statistics), flags)
            try
                for (name, value) in view.statistics
                    ig.TableNextColumn()
                    ig.TextDisabled(name)
                    ig.TextUnformatted(value)
                end
            finally
                ig.EndTable()
            end
        end
    finally
        ig.PopStyleVar()
    end
    return nothing
end

function draw_vector_plots!(view::VectorView, ctx)::Nothing
    # One subplot row aligns all value axes. The color strip is drawn in the trace's own
    # coordinate system, so its index positions cannot drift from the Index axis.
    flags = ig.lib.ImPlotSubplotFlags_NoTitle | ig.lib.ImPlotSubplotFlags_NoLegend
    ig.lib.ImPlot_PushStyleVar_Vec2(ig.lib.ImPlotStyleVar_PlotMinSize, ig.ImVec2(1, 1))
    ig.lib.ImPlot_PushStyleVar_Vec2(ig.lib.ImPlotStyleVar_PlotPadding, ig.ImVec2(10, 10))
    try
        if ig.lib.ImPlot_BeginSubplots("##vector-$(ctx.id)", 1, 3, ig.ImVec2(-1, -1), flags,
                C_NULL, view.distribution_ratios)
            histogram = ecdf = nothing
            try
                draw_vector_trace!(view)
                histogram = draw_vector_histogram!(view)
                ecdf = draw_vector_ecdf!(view)
            finally
                ig.lib.ImPlot_EndSubplots()
            end
            if histogram !== nothing && ecdf !== nothing
                balance_distribution_widths!(view, histogram, ecdf)
            end
        end
    finally
        ig.lib.ImPlot_PopStyleVar(2)
    end
    return nothing
end

function draw_vector_trace!(view::VectorView)::Nothing
    ig.lib.ImPlot_BeginPlot("##trace", ig.ImVec2(-1, -1), VECTOR_PLOT_FLAGS) || return nothing
    try
        ig.lib.ImPlot_SetupAxes("Index", "Value", 0, 0)
        ig.lib.ImPlot_SetupAxisLinks(ig.lib.ImAxis_X1, view.index_min, view.index_max)
        ig.lib.ImPlot_SetupAxisLinks(ig.lib.ImAxis_Y1, view.value_min, view.value_max)
        spec = plot_spec(ig.lib.ImPlotProp_Marker =>
            (view.markers ? ig.lib.ImPlotMarker_Circle : ig.lib.ImPlotMarker_None))
        ig.lib.ImPlot_PlotLine_doublePtrdoublePtr("##trace", view.indices, view.values,
            length(view.values), spec)
        draw_vector_strip!(view)
    finally
        ig.lib.ImPlot_EndPlot()
    end
    return nothing
end

function draw_vector_histogram!(view::VectorView)
    chosen = (view.bins, view.density)
    if chosen != view.histogram_settings
        ig.lib.ImPlot_SetNextAxisToFit(ig.lib.ImAxis_X1)
        width = (view.color_limits[2] - view.color_limits[1]) / view.bins
        map!(d -> d * length(view.finite) * width, view.smooth_counts, view.smooth_density)
    end
    ig.lib.ImPlot_BeginPlot("##distribution", ig.ImVec2(-1, -1), VECTOR_PLOT_FLAGS) || return nothing
    plot_width = 0.0f0
    try
        hidden = ig.lib.ImPlotAxisFlags_NoLabel | ig.lib.ImPlotAxisFlags_NoTickMarks |
            ig.lib.ImPlotAxisFlags_NoTickLabels
        ig.lib.ImPlot_SetupAxes(view.density ? "Density" : "Count", "", 0, hidden)
        ig.lib.ImPlot_SetupAxisLinks(ig.lib.ImAxis_Y1, view.value_min, view.value_max)
        flags = ig.lib.ImPlotHistogramFlags_Horizontal |
            (view.density ? ig.lib.ImPlotHistogramFlags_Density : 0)
        constant = view.cdf_values[2] == view.cdf_values[end-1]
        ig.lib.ImPlot_PlotHistogram_doublePtr("##histogram", view.finite, length(view.finite),
            constant ? 1 : view.bins, 1.0,
            ig.lib.ImPlotRange(view.color_limits...), plot_spec(ig.lib.ImPlotProp_Flags => flags))
        if view.smooth && !isempty(view.smooth_values)
            xs = view.density ? view.smooth_density : view.smooth_counts
            ig.lib.ImPlot_PlotLine_doublePtrdoublePtr("Smoothed distribution", xs,
                view.smooth_values, length(xs), plot_spec(ig.lib.ImPlotProp_LineWeight => 2))
        end
        view.histogram_settings = chosen
        plot_width = ig.lib.ImPlot_GetPlotSize().x
    finally
        ig.lib.ImPlot_EndPlot()
    end
    return (frame=ig.GetItemRectSize().x, plot=plot_width)
end

"""Draw a thin band above the trace, aligned through its exact Index-axis transform."""
function draw_vector_strip!(view::VectorView)::Nothing
    pos, size = ig.lib.ImPlot_GetPlotPos(), ig.lib.ImPlot_GetPlotSize()
    drawlist = ig.lib.ImPlot_GetPlotDrawList()
    lo, hi = view.color_limits
    start = 0
    previous = UInt32(0)
    # Sample at screen-pixel centers. This keeps the strip aligned under zoom, pan and axis
    # inversion, without drawing a separate plot with different axis padding.
    for pixel in 0:ceil(Int, size.x)-1
        x = ig.lib.ImPlot_PixelsToPlot_Float(pos.x + min(pixel + 0.5, size.x), pos.y,
            ig.lib.ImAxis_X1, ig.lib.ImAxis_Y1).x
        i = searchsortedfirst(view.indices, x - 0.5)
        color = UInt32(0)
        if 1 <= i <= length(view.indices) && abs(view.indices[i] - x) <= 0.5 && isfinite(view.values[i])
            t = clamp((view.values[i] - lo) / (hi - lo), 0, 1)
            color = ig.lib.ImPlot_SampleColormapU32(t, ig.lib.ImPlotColormap_Viridis)
        end
        if color != previous
            previous != 0 && ig.AddRectFilled(drawlist, ig.ImVec2(pos.x + start, pos.y - 8),
                ig.ImVec2(pos.x + pixel, pos.y - 1), previous)
            start, previous = pixel, color
        end
    end
    previous != 0 && ig.AddRectFilled(drawlist, ig.ImVec2(pos.x + start, pos.y - 8),
        ig.ImVec2(pos.x + size.x, pos.y - 1), previous)
    return nothing
end

function draw_vector_ecdf!(view::VectorView)
    ig.lib.ImPlot_BeginPlot("##ecdf", ig.ImVec2(-1, -1), VECTOR_PLOT_FLAGS) || return nothing
    plot_width = 0.0f0
    try
        ig.lib.ImPlot_SetupAxes("ECDF", "Value", ig.lib.ImPlotAxisFlags_Lock,
            ig.lib.ImPlotAxisFlags_Opposite)
        ig.lib.ImPlot_SetupAxisLinks(ig.lib.ImAxis_Y1, view.value_min, view.value_max)
        ig.lib.ImPlot_SetupAxisLimits(ig.lib.ImAxis_X1, 0, 1, ig.lib.ImPlotCond_Always)
        view.cdf_values[1] = min(view.value_min[], view.cdf_values[2])
        view.cdf_values[end] = max(view.value_max[], view.cdf_values[end-1])
        ig.lib.ImPlot_PlotStairs_doublePtrdoublePtr("##ecdf", view.cdf_fractions,
            view.cdf_values, length(view.cdf_values),
            plot_spec(ig.lib.ImPlotProp_Flags => ig.lib.ImPlotStairsFlags_PreStep))
        plot_width = ig.lib.ImPlot_GetPlotSize().x
    finally
        ig.lib.ImPlot_EndPlot()
    end
    return (frame=ig.GetItemRectSize().x, plot=plot_width)
end

"""Frame widths that give both plots equal drawing width while retaining each plot's axis space."""
function distribution_frame_widths(histogram, ecdf)
    correction = (histogram.plot - ecdf.plot) / 2
    return (histogram.frame - correction, ecdf.frame + correction)
end

"""Account for measured axis widths when opening, resizing or changing axis labels."""
function balance_distribution_widths!(view::VectorView, histogram, ecdf)::Nothing
    total = histogram.frame + ecdf.frame
    axis_difference = (ecdf.frame - ecdf.plot) - (histogram.frame - histogram.plot)
    previous = view.distribution_geometry
    if isfinite(previous[1]) && abs(total - previous[1]) < 1.5 && abs(axis_difference - previous[2]) < 0.5
        return nothing
    end
    h, e = distribution_frame_widths(histogram, ecdf)
    total > 0 && h > 0 && e > 0 || return nothing
    weight = view.distribution_ratios[2] + view.distribution_ratios[3]
    view.distribution_ratios[2] = weight * h / total
    view.distribution_ratios[3] = weight * e / total
    view.distribution_geometry = (total, axis_difference)
    return nothing
end

"""Draw one horizontal sequence, with an index above each value and wheel scrolling without a scrollbar."""
function draw_vector_numbers!(view::VectorView)::Nothing
    line = ig.GetTextLineHeight()
    characters = max(view.numeric_characters, length(string(Int(last(view.indices)))))
    width = ig.CalcTextSize(repeat("0", characters)).x + 4
    height = 2line + 2
    ig.SetNextWindowContentSize(ig.ImVec2(length(view.values) * width, 0))
    flags = ig.ImGuiWindowFlags_HorizontalScrollbar | ig.ImGuiWindowFlags_NoScrollbar |
        ig.ImGuiWindowFlags_NoScrollWithMouse
    opened = ig.BeginChild("##numbers", ig.ImVec2(0, height), 0, flags)
    try
        opened || return nothing
        if view.numeric_reset
            ig.SetScrollX(0)
            view.numeric_reset = false
        end
        if ig.IsWindowHovered()
            io = ig.GetIO()
            wheel = unsafe_load(io.MouseWheelH) + unsafe_load(io.MouseWheel)
            wheel != 0 && ig.SetScrollX(ig.GetScrollX() - wheel * width * 3)
        end
        first_cell = max(1, floor(Int, ig.GetScrollX() / width) + 1)
        last_cell = min(length(view.values), ceil(Int, (ig.GetScrollX() + ig.GetWindowWidth()) / width))
        for i in first_cell:last_cell
            x = (i - 1) * width
            ig.SetCursorPos(ig.ImVec2(x, 0))
            ig.TextDisabled(string(Int(view.indices[i])))
            ig.SetCursorPos(ig.ImVec2(x, line + 2))
            text = isnan(view.values[i]) ? first(view.value_labels[i], 10) : @sprintf("%.4g", view.values[i])
            ig.TextUnformatted(text)
            ig.SetItemTooltip("[$(Int(view.indices[i]))] $(view.value_labels[i])\nScroll to move along the vector.")
        end
    finally
        ig.EndChild()
    end
    return nothing
end

"""
Estimate a Gaussian density of finite values on a 512-point grid using linear binning. The
bandwidth is 1.06 * std(values) * n^(-1/5), bounded below by the grid resolution. Empty and
constant data have no smooth density. The grid extends four bandwidths beyond the data so that
the density integrates to approximately one.
"""
function vector_density(values::Vector{Float64})::Tuple{Vector{Float64},Vector{Float64}}
    length(values) > 1 || return (Float64[], Float64[])
    lo, hi = extrema(values)
    lo < hi || return (Float64[], Float64[])
    bandwidth = max(1.06 * std(values) * length(values)^(-0.2), (hi - lo) / 256)
    isfinite(bandwidth) && bandwidth > 0 || return (Float64[], Float64[])
    grid_min, grid_max = lo - 4bandwidth, hi + 4bandwidth
    isfinite(grid_min) && isfinite(grid_max) || return (Float64[], Float64[])
    grid = collect(range(grid_min, grid_max; length=512))
    dx = grid[2] - grid[1]
    dx > 0 && isfinite(dx) || return (Float64[], Float64[])
    weights = zeros(length(grid))
    for value in values
        position = (value - first(grid)) / dx + 1
        i = clamp(floor(Int, position), 1, length(grid) - 1)
        fraction = position - i
        weights[i] += 1 - fraction
        weights[i+1] += fraction
    end
    density = zeros(length(grid))
    normalization = length(values) * bandwidth * sqrt(2pi)
    for j in eachindex(weights)
        weights[j] == 0 && continue
        for i in eachindex(grid)
            z = (grid[i] - grid[j]) / bandwidth
            density[i] += weights[j] * exp(-0.5z^2) / normalization
        end
    end
    return (grid, density)
end
