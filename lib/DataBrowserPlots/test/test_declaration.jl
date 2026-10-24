using Test, DataBrowserPlots, GLMakie, AlgebraOfGraphics

plotted(drawn, type) = [p for p in only(filter(c -> c isa Axis, drawn.content)).scene.plots if p isa type]

@testset "a line's positions replace the header's, and nothing removes a role of the header" begin
    rows = [(V=v, I=c == "a" ? v : 2v, I2=-v, Chip=c) for c in ("a", "b") for v in (0.0, 1.0)]
    plot = @plot data(rows) * mapping(:V, :I; color=:Chip) begin
        visual(Lines)
        mapping(:V, :I2; color=nothing) * visual(Scatter)
    end
    drawn = figure(plot)
    @test length(plotted(drawn, Lines)) == 2
    @test last.(only(plotted(drawn, Scatter))[1][]) == [0.0, -1.0, 0.0, -1.0]
end

@testset "@invisible keeps a line without drawing it" begin
    rows = [(V=v, I=v) for v in (0.0, 1.0)]
    plot = @plot data(rows) * mapping(:V, :I) begin
        visual(Lines)
        @invisible visual(Scatter)
    end
    drawn = figure(plot)
    @test length(plotted(drawn, Lines)) == 1
    @test isempty(plotted(drawn, Scatter))
end
