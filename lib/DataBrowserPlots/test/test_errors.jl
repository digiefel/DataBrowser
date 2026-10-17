using Test, DataBrowserPlots, GLMakie
import DataBrowserAPI
using DataBrowserGUI: merge_item_tables

@testset "plot failures retain details and clear them after recovery" begin
    ext = Base.get_extension(DataBrowserPlots, :DataBrowserPlotsGLMakieExt)
    view = ext.BuilderView(description=DataBrowserPlots.PlotDescription(
        layers=[DataBrowserPlots.Layer(:invalid_mark)]))
    table, _ = merge_item_tables([("sample", (x=[1., 2.], y=[3., 4.]))])
    @test_logs (:error, r"Plot builder: drawing failed") DataBrowserAPI.prepare!(view, table, (; id="error_test"))
    @test view.figure === nothing
    @test occursin("Stacktrace:", view.message)
    @test occursin("invalid_mark", view.error_details)
    view.description = DataBrowserPlots.PlotDescription(layers=[DataBrowserPlots.Layer(:lines)])
    DataBrowserAPI.prepare!(view, table, (; id="error_test"))
    @test view.figure isa Figure
    @test isempty(view.message)
    @test isempty(view.error_details)
end
