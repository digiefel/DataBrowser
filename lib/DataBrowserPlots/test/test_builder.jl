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

# A function of the project, defined in Main as a project script does.
Core.eval(Main, :(doubled_for_builder_test(x) = 2x))
Core.eval(Main, :(gap_label_for_builder_test() = "from Main"))

@testset "the plot file reaches the names defined in Main, and may define its own" begin
    ext = Base.get_extension(DataBrowserPlots, :DataBrowserPlotsBuilderExt)
    selection = Selection(StructArray((; id=["a", "b"], label=["a", "b"], gap=[1.0, 2.0], R=[3.0, 5.0])))
    mktempdir() do directory
        file = joinpath(directory, "plot.jl")
        write(file, """
            R2 = doubled_for_builder_test.(selection.R)
            gap_label_for_builder_test() = "gap"
            @plot data((; gap=selection.gap, R2)) * mapping(:gap => gap_label_for_builder_test(), :R2) * visual(Lines)
            """)
        view = ext.BuilderView(; file)
        DataBrowserAPI.prepare!(view, selection, (; id="window"))
        axis = only(content for content in view.figure.content if content isa Axis)
        @test axis.xlabel[] == "gap"
        @test last.(only(axis.scene.plots)[1][]) == [6.0, 10.0]
    end
end

@testset "@plot without data draws the paths of the items it is given" begin
    items = (device=["D1", "D2"], data=(V=[[0.0, 1.0], [0.0, 2.0]], I=[[0.0, 1.0], [0.0, 3.0]]))
    curves = @plot mapping(:data.V, :data.I; color=:device) * visual(Lines)
    @test figure(curves, items) isa Figure
    peaks = @plot mapping(:device, maximum(:data.I)) begin
        visual(Scatter)
    end
    @test figure(peaks, items) isa Figure
    # Each layer has its own table: one peak per item next to the rows of each item.
    both = @plot mapping(:data.V, :data.I) * visual(Lines) + mapping(last(:data.V), maximum(:data.I)) * visual(Scatter)
    axis = only(filter(c -> c isa Axis, figure(both, items).content))
    @test length(only(filter(p -> p isa Scatter, axis.scene.plots))[1][]) == 2
end
