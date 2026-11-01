"""Set the shared frequency range for a linear or logarithmic axis."""
function reset_vector_frequency!(view::VectorView)::Nothing
    frequencies = view.signal_data.frequency
    if isempty(frequencies)
        view.frequency_min[], view.frequency_max[] = 0, 0.5
    elseif view.log_frequency
        lo, hi = frequencies[2], last(frequencies)
        lo == hi && ((lo, hi) = (lo / 2, hi * 2))
        view.frequency_min[], view.frequency_max[] = lo, hi
    else
        view.frequency_min[], view.frequency_max[] = 0, last(frequencies)
    end
    view.frequency_was_log = view.log_frequency
    return nothing
end

"""Draw the prepared spectrum, PSD and autocorrelation when Frequency Analysis is selected."""
function draw_vector_signal!(view::VectorView, ctx)::Nothing
    data = view.signal_data
    if !isempty(data.issue)
        ig.TextWrapped(data.issue)
        return nothing
    end
    view.frequency_was_log != view.log_frequency && reset_vector_frequency!(view)
    if view.amplitude_was_log != view.log_amplitude
        view.amplitude_was_log = view.log_amplitude
        view.signal_fit = true
    end
    flags = ig.lib.ImPlotSubplotFlags_NoTitle | ig.lib.ImPlotSubplotFlags_NoLegend
    ig.lib.ImPlot_PushStyleVar_Vec2(ig.lib.ImPlotStyleVar_PlotMinSize, ig.ImVec2(1, 1))
    try
        if ig.lib.ImPlot_BeginSubplots("##signal-$(ctx.id)", 3, 1, ig.ImVec2(-1, -1), flags,
                C_NULL, C_NULL)
            try
                draw_vector_spectrum!(view, data.amplitude, "FFT amplitude", true)
                draw_vector_spectrum!(view, data.psd, "PSD (Hann)", false)
                draw_vector_correlation!(view)
                view.signal_fit = false
            finally
                ig.lib.ImPlot_EndSubplots()
            end
        end
    finally
        ig.lib.ImPlot_PopStyleVar(1)
    end
    return nothing
end

function draw_vector_spectrum!(view::VectorView, values::Vector{Float64}, name::String, hide_x::Bool)::Nothing
    view.signal_fit && ig.lib.ImPlot_SetNextAxisToFit(ig.lib.ImAxis_Y1)
    ig.lib.ImPlot_BeginPlot("##$name", ig.ImVec2(-1, -1), VECTOR_PLOT_FLAGS) || return nothing
    try
        hidden = ig.lib.ImPlotAxisFlags_NoLabel | ig.lib.ImPlotAxisFlags_NoTickLabels |
            ig.lib.ImPlotAxisFlags_NoTickMarks
        ig.lib.ImPlot_SetupAxes(hide_x ? "" : "Frequency (cycles / unit)", name, hide_x ? hidden : 0, 0)
        ig.lib.ImPlot_SetupAxisScale_PlotScale(ig.lib.ImAxis_X1,
            view.log_frequency ? ig.lib.ImPlotScale_Log10 : ig.lib.ImPlotScale_Linear)
        ig.lib.ImPlot_SetupAxisScale_PlotScale(ig.lib.ImAxis_Y1,
            view.log_amplitude ? ig.lib.ImPlotScale_Log10 : ig.lib.ImPlotScale_Linear)
        ig.lib.ImPlot_SetupAxisLinks(ig.lib.ImAxis_X1, view.frequency_min, view.frequency_max)
        first_bin = view.log_frequency ? 2 : 1
        xs = @view view.signal_data.frequency[first_bin:end]
        ys = @view values[first_bin:end]
        spec = plot_spec(ig.lib.ImPlotProp_Marker =>
            (view.markers ? ig.lib.ImPlotMarker_Circle : ig.lib.ImPlotMarker_None))
        ig.lib.ImPlot_PlotLine_doublePtrdoublePtr("##spectrum", xs, ys, length(ys), spec)
    finally
        ig.lib.ImPlot_EndPlot()
    end
    return nothing
end

function draw_vector_correlation!(view::VectorView)::Nothing
    data = view.signal_data
    ig.lib.ImPlot_BeginPlot("##correlation", ig.ImVec2(-1, -1), VECTOR_PLOT_FLAGS) || return nothing
    try
        ig.lib.ImPlot_SetupAxes("Lag (sample units)", "Autocorrelation", 0, ig.lib.ImPlotAxisFlags_Lock)
        ig.lib.ImPlot_SetupAxisLimits(ig.lib.ImAxis_Y1, -1.05, 1.05, ig.lib.ImPlotCond_Always)
        view.signal_fit && ig.lib.ImPlot_SetupAxisLimits(ig.lib.ImAxis_X1, 0, last(data.lag), ig.lib.ImPlotCond_Always)
        if isempty(data.correlation)
            ig.lib.ImPlot_PlotText("Undefined for a constant signal", last(data.lag) / 2, 0,
                ig.ImVec2(0, 0), plot_spec(ig.lib.ImPlotProp_Flags => ig.lib.ImPlotItemFlags_NoFit))
        else
            spec = plot_spec(ig.lib.ImPlotProp_Marker =>
                (view.markers ? ig.lib.ImPlotMarker_Circle : ig.lib.ImPlotMarker_None))
            ig.lib.ImPlot_PlotLine_doublePtrdoublePtr("##correlation", data.lag,
                data.correlation, length(data.correlation), spec)
        end
    finally
        ig.lib.ImPlot_EndPlot()
    end
    return nothing
end
