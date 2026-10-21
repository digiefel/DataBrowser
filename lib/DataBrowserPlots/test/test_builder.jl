using Test, DataBrowserPlots, GLMakie, AlgebraOfGraphics
import DataBrowserAPI
using DataBrowserCore: Selection
using DataBrowserCore.Workspace.StructArrays: StructArray

@testset "a new plot draws the selection's columns, and a name saves its code" begin
    ext = Base.get_extension(DataBrowserPlots, :DataBrowserPlotsBuilderExt)
    labels = Selection(StructArray((; id=["a", "b"], label=["a", "b"])))
    view = ext.BuilderView()
    DataBrowserAPI.prepare!(view, labels, (; id="window"))
    @test view.figure isa Figure

    numbers = Selection(StructArray((; id=["a", "b"], label=["a", "b"], gap=[1.0, 2.0], R=[3.0, 5.0])))
    DataBrowserAPI.prepare!(view, numbers, (; id="window"))
    @test occursin("mapping(:gap, :R)", view.code)
    @test view.figure isa Figure

    mktempdir() do directory
        view.file = joinpath(directory, "plot.jl")
        DataBrowserAPI.prepare!(view, numbers, (; id="window"))
        @test read(view.file, String) == view.code
    end
end

@testset "the plot builder draws the code saved in its file, which may load packages" begin
    ext = Base.get_extension(DataBrowserPlots, :DataBrowserPlotsBuilderExt)
    selection = Selection(StructArray((; id=["a", "b"], label=["a", "b"], gap=[1.0, 2.0], R=[3.0, 5.0])))
    mktempdir() do directory
        file = joinpath(directory, "plot.jl")
        write(file, """
            using Printf
            @plot data(selection) * mapping(:gap, :R => @sprintf("R (%s)", "Ω")) begin
                visual(Lines)
            end
            """)
        view = ext.BuilderView(; file)
        DataBrowserAPI.prepare!(view, selection, (; id="window"))
        axis = only(content for content in view.figure.content if content isa Axis)
        @test only(axis.scene.plots) isa Lines
    end
end
