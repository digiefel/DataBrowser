@plot data(measurements) *
    mapping(:gap_um => "gap (µm)", :R_ohm => "R (Ω)"; color=:chip, col=:site) begin
    visual(Scatter; markersize=6)
    fit = linear(; interval=nothing) *
        subvisual(:prediction; linewidth=2,
            linestyle=fit.r2 < 0.99 ? :dash : :solid)
    mapping(fit.x[end], fit.y[end]) *
        visual(Text; text="R_c = $(round(fit.intercept / 2; digits=1)) Ω",
            fontsize=12, offset=(8, 0), align=(:left, :center))
    mapping(0, fit.intercept) * visual(Scatter; marker=:xcross, markersize=12)
    mapping(; group=nothing, color=nothing) * linear(; interval=nothing) *
        subvisual(:prediction; color=:gray, linestyle=:dot)
end