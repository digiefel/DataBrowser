using Test, DataBrowserPlots, DataBrowserGUI, GLMakie, AlgebraOfGraphics
# The code edits of the plot builder.
const Builder = Base.get_extension(DataBrowserPlots, :DataBrowserPlotsGUIExt).Builder
using .Builder: add_layer!, set_analysis!

@testset "adding layers preserves plot source" begin
    rows = (t=[0.,1.], v=[0.,5.])
    for source in (
        "# original comment\n@plot data(rows) * mapping(:t, :v) begin\nend\n",
        "# original comment\n@plot data(rows) * mapping(:t, :v) * visual(Lines; color=:blue)\n",
        "# original comment\n@plot data(rows) * mapping(:t, :v) begin\n    visual(Lines; color=:blue) # keep this comment\nend\n",
    )
        code = CodeFile(; text=source)
        @test add_layer!(code, :Scatter) === code
        @test startswith(code.text, "# original comment\n")
        @test occursin("mapping(:t, :v)", code.text)
        occursin("# keep this comment", source) && @test occursin("visual(Lines; color=:blue) # keep this comment", code.text)
        mod = Module(:AddedLayer)
        Core.eval(mod, :(using DataBrowserPlots, GLMakie, AlgebraOfGraphics))
        Core.eval(mod, :(rows = $rows))
        f = figure(Base.include_string(mod, code.text))
        plots = only(filter(c -> c isa Axis, f.content)).scene.plots
        @test length(filter(p -> p isa Scatter, plots)) == 1
        if occursin("visual(Lines", source)
            line = only(filter(p -> p isa Lines, plots))
            @test line.color[] == GLMakie.to_color(:blue)
        end
    end
end

@testset "changing an analysis preserves the layer and changes its plotted values" begin
    rows = (t=[1.,1.,2.,2.], v=[10.,14.,20.,24.])
    code = CodeFile(; text="""
        @plot data(rows) * mapping(; x=:t, y2=:v) begin
            visual(Lines; color=:blue) # measured trace
            scales(y2=(;position=:right))
        end
        """)
    function drawn_trace(code)
        mod = Module(:AnalysisLayer)
        Core.eval(mod, :(using DataBrowserPlots, GLMakie, AlgebraOfGraphics))
        Core.eval(mod, :(rows = $rows))
        f = figure(Base.include_string(mod, code.text))
        right = only(filter(c -> c isa Axis && c.yaxisposition[] == :right, f.content))
        return only(filter(p -> p isa Lines && !isempty(p[1][]), right.scene.plots))
    end
    @test length(drawn_trace(code)[1][]) == 4
    @test set_analysis!(code, 1, "expectation()") === code
    expected = drawn_trace(code)
    @test Tuple.(expected[1][]) == [(1.,12.), (2.,22.)]
    @test expected.color[] == GLMakie.to_color(:blue)
    set_analysis!(code, 1, "linear(interval=nothing, npoints=7)")
    @test length(drawn_trace(code)[1][]) == 7
    set_analysis!(code, 1, nothing)
    @test length(drawn_trace(code)[1][]) == 4
    @test occursin("# measured trace", code.text)
end
