using Test, DataBrowserPlots, GLMakie, AlgebraOfGraphics
import DataBrowserAPI
using DataBrowserCore: Selection
using DataBrowserCore.Workspace.StructArrays: StructArray

@testset "plot failures retain details and clear them after recovery" begin
    ext = Base.get_extension(DataBrowserPlots, :DataBrowserPlotsBuilderExt)
    selection = Selection(StructArray((; id=["sample"], label=["sample"], x=[1.0], y=[3.0])))
    mktempdir() do directory
        file = joinpath(directory, "plot.jl")
        write(file, "@plot data(selection) * mapping(:x, :missing_column) begin\n    visual(Scatter)\nend\n")
        view = ext.BuilderView(; file)
        @test_logs (:error, r"Plot builder") DataBrowserAPI.prepare!(view, selection, (; id="error_test"))
        @test view.figure === nothing
        @test occursin("Stacktrace:", view.message)
        @test occursin("missing_column", view.error_details)

        write(file, "@plot data(selection) * mapping(:x, :y) begin\n    visual(Scatter)\nend\n")
        view.loaded = ""
        DataBrowserAPI.prepare!(view, selection, (; id="error_test"))
        @test view.figure isa Figure
        @test isempty(view.message)
        @test isempty(view.error_details)
    end
end
