"""
    @plot header begin
        layer
        ...
    end

A plot declaration of one panel: a header that every layer shares, and one layer per line.

    @plot data(measurements) * mapping(:gap_um => "gap (µm)", :R_ohm => "R (Ω)"; color=:chip) begin
        visual(Scatter; markersize=6)
        linear(; interval=nothing) * subvisual(:prediction; linewidth=2)
    end

The header and the layers are AlgebraOfGraphics declarations. Each line is multiplied by the
header, and the lines are added, in order: the declaration above is

    data(measurements) * mapping(...) * (visual(Scatter; markersize=6) + linear(...) * subvisual(...))

Draw it with [`figure`](@ref). Write the layers with `*` within a line; a line that continues on
the next one ends with `*`.

TODO: named layers, `fit = linear(...)`, whose results the following lines use (roadmap 0.11.0).
"""
macro plot(header, block)
    Meta.isexpr(block, :block) || error("@plot takes a header and a `begin ... end` block of layers")
    layers = filter(line -> !(line isa LineNumberNode), block.args)
    for layer in layers
        Meta.isexpr(layer, :(=)) && error("@plot does not name layers yet: $layer")
    end
    isempty(layers) && return esc(header)
    return esc(:($header * +($(layers...))))
end
