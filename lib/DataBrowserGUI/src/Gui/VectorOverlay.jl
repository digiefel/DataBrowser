# Overlay is Vector-specific: every item keeps its own samples, distributions and spectra.

function draw_vector_overlay!(view::VectorView, ctx)::Nothing
    view.frequency_was_log != view.log_frequency && reset_overlay_frequency!(view)
    if view.frequency_was_log != view.log_frequency || view.amplitude_was_log != view.log_amplitude ||
            view.histogram_settings != (view.bins, view.density)
        view.signal_fit = true
        view.frequency_was_log, view.amplitude_was_log = view.log_frequency, view.log_amplitude
        view.histogram_settings = (view.bins, view.density)
    end
    for child in view.overlay, name in keys(settings(view))
        setproperty!(child, name, getproperty(view, name))
    end
    active = something(findfirst(==(view.overlay_active), view.overlay_ids), 1)
    child = view.overlay[active]
    isempty(child.values) || draw_vector_numbers!(child)
    ig.TextDisabled(view.overlay_labels[active])
    draw_vector_statistics!(child)
    ## Short spectra or a nonfinite sample affect only their own item.
    if view.signal
        for (i, child) in enumerate(view.overlay)
            isempty(child.signal_data.issue) || ig.TextWrapped("$(view.overlay_labels[i]): $(child.signal_data.issue)")
        end
    end
    ig.lib.ImPlot_PushStyleVar_Vec2(ig.lib.ImPlotStyleVar_PlotMinSize, ig.ImVec2(1, 1))
    try
        if ig.lib.ImPlot_BeginSubplots("##overlay-$(ctx.id)", view.signal ? 3 : 1,
                view.signal ? 1 : 3, ig.ImVec2(-1, -1), ig.lib.ImPlotSubplotFlags_NoTitle,
                C_NULL, C_NULL)
            try
                if view.signal
                    _vector_overlay_plot!(view, :amplitude, "Frequency (cycles / unit)", "FFT amplitude")
                    _vector_overlay_plot!(view, :psd, "Frequency (cycles / unit)", "PSD (Hann)")
                    _vector_overlay_plot!(view, :correlation, "Lag (sample units)", "Autocorrelation")
                else
                    _vector_overlay_plot!(view, :trace, "Index", "Value")
                    _vector_overlay_plot!(view, :histogram, view.density ? "Density" : "Count", "Value")
                    _vector_overlay_plot!(view, :ecdf, "ECDF", "Value")
                end
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

function _vector_overlay_plot!(view::VectorView, kind::Symbol, x::String, y::String)::Nothing
    view.signal_fit && ig.lib.ImPlot_SetNextAxesToFit()
    ig.lib.ImPlot_BeginPlot("##$kind", ig.ImVec2(-1, -1), ig.lib.ImPlotFlags_NoTitle) || return nothing
    try
        ig.lib.ImPlot_SetupAxes(x, y, 0, 0)
        if kind in (:trace, :histogram, :ecdf)
            ig.lib.ImPlot_SetupAxisLinks(ig.lib.ImAxis_Y1, view.value_min, view.value_max)
            kind == :trace && ig.lib.ImPlot_SetupAxisLinks(ig.lib.ImAxis_X1, view.index_min, view.index_max)
        end
        if kind in (:amplitude, :psd)
            ig.lib.ImPlot_SetupAxisLinks(ig.lib.ImAxis_X1, view.frequency_min, view.frequency_max)
            ig.lib.ImPlot_SetupAxisScale_PlotScale(ig.lib.ImAxis_X1,
                view.log_frequency ? ig.lib.ImPlotScale_Log10 : ig.lib.ImPlotScale_Linear)
            ig.lib.ImPlot_SetupAxisScale_PlotScale(ig.lib.ImAxis_Y1,
                view.log_amplitude ? ig.lib.ImPlotScale_Log10 : ig.lib.ImPlotScale_Linear)
        end
        for (i, child) in enumerate(view.overlay)
            name = "$(view.overlay_labels[i])###$(view.overlay_ids[i])"
            color = ig.lib.ImPlot_GetColormapColorU32(i - 1, -1)
            spec = plot_spec(ig.lib.ImPlotProp_LineColor => color,
                ig.lib.ImPlotProp_FillColor => color, ig.lib.ImPlotProp_FillAlpha => 0.25,
                ig.lib.ImPlotProp_Marker => (view.markers ? ig.lib.ImPlotMarker_Circle : ig.lib.ImPlotMarker_None))
            if kind == :trace
                ig.lib.ImPlot_PlotLine_doublePtrdoublePtr(name, child.indices, child.values, length(child.values), spec)
            elseif kind == :ecdf
                isempty(child.finite) && continue
                ig.lib.ImPlot_PlotStairs_doublePtrdoublePtr(name, child.cdf_fractions, child.cdf_values,
                    length(child.cdf_values), spec)
            elseif kind == :histogram
                isempty(child.finite) && continue
                flags = ig.lib.ImPlotHistogramFlags_Horizontal |
                    (view.density ? ig.lib.ImPlotHistogramFlags_Density : 0)
                bins = first(child.cdf_values) == last(child.cdf_values) ? 1 : view.bins
                ig.lib.ImPlot_PlotHistogram_doublePtr(name, child.finite, length(child.finite), bins,
                    1.0, ig.lib.ImPlotRange(child.color_limits...),
                    plot_spec(ig.lib.ImPlotProp_Flags => flags, ig.lib.ImPlotProp_FillColor => color,
                        ig.lib.ImPlotProp_FillAlpha => 0.25, ig.lib.ImPlotProp_LineColor => color))
                if view.smooth && !isempty(child.smooth_values)
                    width = (child.color_limits[2] - child.color_limits[1]) / view.bins
                    xs = view.density ? child.smooth_density : child.smooth_density .* (length(child.finite) * width)
                    ig.lib.ImPlot_PlotLine_doublePtrdoublePtr(name, xs, child.smooth_values, length(xs), spec)
                end
            else
                data = child.signal_data
                isempty(data.issue) || continue
                xs = kind == :correlation ? data.lag : data.frequency
                ys = getproperty(data, kind)
                isempty(ys) && continue
                first_bin = kind != :correlation && view.log_frequency ? 2 : 1
                xs, ys = @view(xs[first_bin:end]), @view(ys[first_bin:end])
                ig.lib.ImPlot_PlotLine_doublePtrdoublePtr(name, xs, ys, length(ys), spec)
            end
        end
        if kind == :trace
            active = something(findfirst(==(view.overlay_active), view.overlay_ids), 1)
            draw_vector_strip!(view.overlay[active])
        end
    finally
        ig.lib.ImPlot_EndPlot()
    end
    return nothing
end

"""Reset the linked FFT/PSD frequency range to cover all usable spectra."""
function reset_overlay_frequency!(view::VectorView)::Nothing
    spectra = filter(child -> isempty(child.signal_data.issue) && length(child.signal_data.frequency) > 1, view.overlay)
    if isempty(spectra)
        view.frequency_min[], view.frequency_max[] = 0, 0.5
    else
        lo = view.log_frequency ? minimum(child -> child.signal_data.frequency[2], spectra) : 0.0
        hi = maximum(child -> last(child.signal_data.frequency), spectra)
        lo == hi && ((lo, hi) = (lo / 2, hi * 2))
        view.frequency_min[], view.frequency_max[] = lo, hi
    end
    return nothing
end
