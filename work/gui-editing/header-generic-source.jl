@plot data(table) * mapping(:x, :y; color=:series) begin
    visual(Scatter; markersize=6)
    fit = linear(; interval=nothing) *
        subvisual(:prediction; linewidth=2)
    mapping(fit.x[end], fit.y[end]) *
        visual(Text; text="Gain = $(round(fit.slope; digits=2))",
            fontsize=13, offset=(8, 0), align=(:left, :center))
end