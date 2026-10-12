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
