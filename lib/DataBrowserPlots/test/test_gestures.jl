using Test, DataBrowserPlots, GLMakie

const Gestures = Base.get_extension(DataBrowserPlots, :DataBrowserPlotsGLMakieExt).MakieImguiIntegration

@testset "axes that share a cell zoom together" begin
    figure = Figure()
    left = Axis(figure[1, 1])
    right = Axis(figure[1, 1]; yaxisposition=:right)
    linkxaxes!(left, right)
    limits!(left, 0, 8, 0, 4)
    limits!(right, 0, 8, 0, 400)

    Gestures.reframe!(axis -> ((0.25, 0.75), (0.5, 1.0)), [left, right])

    @test left.targetlimits[] ≈ Rect2d(2, 2, 4, 2)
    @test right.targetlimits[] ≈ Rect2d(2, 200, 4, 200)
end

@testset "log scales reject nonpositive data without changing the axis" begin
    for values in ([-1., 2.], [0., 2.]), dim in (1, 2)
        fig = Figure()
        ax = Axis(fig[1, 1])
        lines!(ax, dim == 1 ? values : [1., 2.], dim == 2 ? values : [1., 2.])
        before = ax.targetlimits[]
        @test !Gestures._set_axis_scale!(ax, dim, log10)
        @test ax.xscale[] === ax.yscale[] === identity
        @test ax.targetlimits[] == before
        @test Gestures._set_axis_scale!(ax, dim, GLMakie.Makie.pseudolog10)
    end
    fig = Figure()
    ax = Axis(fig[1, 1])
    lines!(ax, [1., 2.], [1., 10.])
    @test Gestures._set_axis_scale!(ax, 2, log10)
    @test ax.yscale[] === log10
    @test Gestures._set_axis_scale!(ax, 2, identity)
    ylims!(ax, -1, 11)
    @test !Gestures._set_axis_scale!(ax, 2, log10)
    @test ax.yscale[] === identity
end

@testset "failed scale notifications restore a usable plot" begin
    fig = Figure()
    ax = Axis(fig[1, 1])
    lines!(ax, [1., 2.], [1., 10.])
    before = ax.targetlimits[]
    listener = on(ax.yscale) do scale
        scale === log10 && error("scale callback failed")
    end
    @test_logs (:warn, r"previous scale was restored") @test !Gestures._set_axis_scale!(ax, 2, log10)
    @test ax.yscale[] === identity
    @test ax.scene.transformation.transform_func[][2] === identity
    @test ax.targetlimits[] == before
    off(listener)
    @test Gestures._set_axis_scale!(ax, 2, log10)
end

@testset "pseudolog adapts to each axis and preserves signed small values" begin
    fig = Figure()
    ax = Axis(fig[1, 1])
    lines!(ax, [-100., -2., 0., 2., 100.], [-1e-9, -1e-12, 0., 1e-12, 1e-9])
    for (dim, smallest) in ((1, 2.), (2, 1e-12))
        scale = Gestures._axis_pseudolog10(ax, dim)
        @test scale(smallest) ≈ log10(2)
        values = [-1000smallest, -smallest, 0., smallest, 1000smallest]
        @test issorted(scale.(values))
        @test scale(0.) == 0.
        @test GLMakie.Makie.inverse_transform(scale).(scale.(values)) ≈ values
        @test Gestures._set_axis_scale!(ax, dim, scale)
    end
    empty_axis = Axis(fig[1, 2])
    scatter!(empty_axis, [0.], [0.])
    @test isfinite(Gestures._axis_pseudolog10(empty_axis, 2)(1.))
end

@testset "pseudolog ticks use original-unit decades" begin
    scale = Gestures.AxisPseudolog10(2e-12)
    ticks, labels = GLMakie.Makie.get_ticks(GLMakie.Makie.automatic, scale, GLMakie.Makie.automatic, -1e-9, 1e-9)
    @test ticks ≈ [-1e-9, -1e-10, 0., 1e-10, 1e-9]
    @test length(labels) == length(ticks)
    for (lo, hi) in ((1e-11, 1e-8), (-1e-8, -1e-11), (2e-10, 3e-10), (-1e-13, 1e-13))
        ticks, labels = GLMakie.Makie.get_ticks(GLMakie.Makie.automatic, scale, GLMakie.Makie.automatic, lo, hi)
        @test !isempty(ticks)
        @test issorted(ticks)
        @test all(t -> lo <= t <= hi, ticks)
    end
    ticks, labels = GLMakie.Makie.get_ticks(GLMakie.Makie.automatic, scale, xs -> string.(xs), -1e-9, 1e-9)
    @test labels == string.(ticks)
end
