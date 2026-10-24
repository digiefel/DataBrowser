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

@testset "item paths draw each trace and one peak per item" begin
    items = (device=["D1", "D2"], data=(V=[[0.0, 1.0], [0.0, 2.0]], I=[[0.0, 1.0], [0.0, 3.0]]))
    curves = @plot mapping(:data.V, :data.I; color=:device) * visual(Lines)
    @test [Tuple.(p[1][]) for p in plotted(figure(curves, items), Lines)] ==
        [[(0.0, 0.0), (1.0, 1.0)], [(0.0, 0.0), (2.0, 3.0)]]

    peaks = @plot mapping(:device, maximum(:data.I)) * visual(Scatter)
    @test last.(only(plotted(figure(peaks, items), Scatter))[1][]) == [1.0, 3.0]

    both = @plot mapping(:data.V, :data.I) * visual(Lines) + mapping(last(:data.V), maximum(:data.I)) * visual(Scatter)
    @test Tuple.(only(plotted(figure(both, items), Scatter))[1][]) == [(1.0, 1.0), (2.0, 3.0)]
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

@testset "a line leaves out a role of the header that its plot type cannot show" begin
    rows = (V=Float64[1:4;], I=[1.0, 3, 2, 4], P=Float64[1:4;])
    plot = @plot data(rows) * mapping(:V, :I; markersize=:P) begin
        visual(Scatter)
        visual(Lines)
    end
    drawn = figure(plot)
    @test length(plotted(drawn, Scatter)) == 1
    @test length(plotted(drawn, Lines)) == 1
    # A role of the line's own mapping is not left out.
    @test_throws ArgumentError figure(@plot data(rows) * mapping(:V, :I) begin
        mapping(; markersize=:P) * visual(Lines)
    end)
end

@testset "the limits of a scale remove the values outside them before the analyses run" begin
    rows = (x=[1.0, 1, 2, 2], y=[1.0, 10, 2, 20])
    plot = @plot data(rows) * mapping(:x, :y) begin
        expectation() * visual(Lines)
        scales(y = (; limits = (0, 15)))
    end
    @test last.(only(plotted(figure(plot), Lines))[1][]) ≈ [5.5, 2.0]
end
