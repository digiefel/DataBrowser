using Test, DataBrowserPlots, GLMakie, AlgebraOfGraphics

@testset "y2 scale controls its axis, with shared x" begin
    p = @plot data((t=[0.,1.,2.], V=[0.,5.,0.], I=[0.,1e-6,0.])) * mapping(; x=:t, y=:V, y2=:I, color=ydims()) begin
        visual(Lines)
        scales(x=(;label="Time (s)"), y=(;label="Voltage (V)"), y2=(;position=:right, label="Current (A)"))
    end
    f = figure(p)
    axes = filter(a -> a isa Axis, f.content)
    @test length(axes) == 2
    left = only(filter(a -> a.yaxisposition[] == :left, axes))
    right = only(filter(a -> a.yaxisposition[] == :right, axes))
    @test left.ylabel[] == "Voltage (V)"
    @test right.ylabel[] == "Current (A)"
    @test left.xlabel[] == "Time (s)"
    @test last.(only(left.scene.plots)[1][]) == [0.,5.,0.]
    @test last.(only(right.scene.plots)[1][]) ≈ [0.,1e-6,0.]
    @test right.targetlimits[].widths[2] < 2e-6
    xlims!(left, 0.5, 1.5)
    @test right.targetlimits[].origin[1] ≈ 0.5
    @test right.targetlimits[].widths[1] ≈ 1.0
    @test right.targetlimits[].widths[2] < 2e-6
    @test only(left.scene.plots).color[] != only(right.scene.plots).color[]
    legend = only(filter(c -> c isa Legend, f.content))
    @test sort([entry.label[] for (_, entries) in legend.entrygroups[] for entry in entries]) == ["I", "V"]
end

@testset "every defined yN inherits unspecified y settings" begin
    p = @plot data((x=[1.,2.,3.], v=[1.,2.,3.], i=[10.,100.,1000.])) * mapping(; x=:x, y=:v, y7=:i) begin
        visual(Lines)
        scales(y=(;label="Inherited", scale=log10, reversed=true), y7=(;position=:right, limits=(10.,1000.)))
    end
    axes = filter(a -> a isa Axis, figure(p).content)
    @test length(axes) == 2
    right = only(filter(a -> a.yaxisposition[] == :right, axes))
    @test right.ylabel[] == "Inherited"
    @test right.yscale[] === log10
    @test right.yreversed[]
    @test right.targetlimits[].origin[2] ≈ 10.
    @test right.targetlimits[].origin[2] + right.targetlimits[].widths[2] ≈ 1000.
end

@testset "yN defaults to the same scale as y" begin
    p = @plot data((x=[1.,2.], a=[1.,10.], b=[10.,100.])) * mapping(; x=:x, y=:a, y3=:b) begin
        visual(Scatter)
        scales(y=(;scale=log10, label="Shared"))
    end
    axes = filter(a -> a isa Axis, figure(p).content)
    @test length(axes) == 1
    @test only(axes).yscale[] === log10
    @test only(axes).ylabel[] == "Shared"
    @test sort(last.(only(only(axes).scene.plots)[1][])) == [1.,10.,10.,100.]
end

@testset "separate layers can map y2, and hidden layers do not create axes" begin
    p = @plot data((x=[0.,1.], y=[0.,1e-6])) * mapping(:x,:y) begin
        visual(Lines)
        @invisible mapping(; y2=:y) * visual(Scatter)
        scales(y2=(;position=:right))
    end
    @test length(filter(a -> a isa Axis, figure(p).content)) == 1
    rightonly = @plot data((x=[0.,1.], y=[0.,1e-6])) * mapping(; x=:x, y2=:y) begin
        visual(Lines)
        scales(y2=(;position=:right))
    end
    axes = filter(a -> a isa Axis, figure(rightonly).content)
    right = only(filter(a -> a.yaxisposition[] == :right, axes))
    @test last.(only(right.scene.plots)[1][]) ≈ [0.,1e-6]
    @test right.targetlimits[].widths[2] < 2e-6
    @test right.targetlimits[].widths[1] < 2
end

@testset "color guides can be hidden with independent y scales" begin
    hidden = @plot data((x=[1.,2.], a=[1.,2.], b=[3.,4.])) * mapping(;x=:x,y=:a,y2=:b,color=ydims()) begin
        visual(Lines)
        scales(y2=(;position=:right),color=(;legend=false))
    end
    @test !any(c -> c isa Legend, figure(hidden).content)
end
