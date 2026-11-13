using Test, CairoMakie, Grafico

axes_of(fig) = filter(x -> x isa Axis,fig.content)
function plots_of(fig,T)
    found=Any[]
    function visit(p)
        p isa T && push!(found,p)
        foreach(visit,p.plots)
    end
    for axis in axes_of(fig), p in axis.scene.plots
        visit(p)
    end
    found
end

@testset "Observable data and mappings" begin
    rows=Observable((x=[1.,2.,3.],y=[2.,4.,6.],z=[3.,6.,9.]))
    selected=Observable(:y)
    colour=Observable(:red)
    declaration=data(rows)*mapping(:x,selected)*visual(Lines;color=colour)
    @test declaration isa Observable
    @test spec(declaration) isa Makie.GridLayoutSpec
    fig=figure(declaration)
    axis=only(axes_of(fig))
    line=only(plots_of(fig,Lines))
    @test last.(line[1][]) ≈ [2,4,6]
    colour[]=:blue
    @test line.color[] == RGBAf(0,0,1,1)
    rows[]=(x=[1.,2.,3.],y=[4.,8.,12.],z=[5.,10.,15.])
    @test only(axes_of(fig)) === axis
    @test only(plots_of(fig,Lines)) === line
    @test last.(line[1][]) ≈ [4,8,12]
    selected[]=:z
    @test last.(only(plots_of(fig,Lines))[1][]) ≈ [5,10,15]
    colour[]=:green
    @test only(plots_of(fig,Lines)).color[] == Makie.to_color(:green)

    column=Observable([1.,3.,2.])
    fig=figure(data((x=[1.,2.,3.],y=column))*mapping(:x,:y)*visual(Scatter))
    points=only(plots_of(fig,Scatter))
    column[]=[2.,6.,4.]
    @test last.(points[1][]) ≈ [2,6,4]

    transform=Observable{Function}(identity)
    fig=figure(data((x=[1.,2.],y=[2.,3.]))*mapping(:x,:y=>transform)*visual(Lines))
    transform[]=x->x^2
    @test last.(only(plots_of(fig,Lines))[1][]) ≈ [4,9]
end

@testset "@plot keeps Observable sources" begin
    rows=Observable((x=[1.,2.],y=[2.,3.]))
    declaration=@plot data(rows)*mapping(:x,:y) begin
        visual(Lines)
        visual(Scatter)
    end
    fig=figure(declaration)
    rows[]=(x=[1.,2.],y=[5.,8.])
    @test last.(only(plots_of(fig,Lines))[1][]) ≈ [5,8]
    @test last.(only(plots_of(fig,Scatter))[1][]) ≈ [5,8]
end

@testset "Appearance and coordinate changes preserve scientific work" begin
    calls=Ref(0)
    counted=transformation(p->(calls[]+=1;p))
    colour=Observable(:red)
    window=Observable((0.,4.))
    graph=data((x=[1.,2.,3.],y=[2.,3.,4.]))*mapping(:x,:y)*counted*visual(Lines;color=colour)
    graph=graph+coord(x=(;limits=window))
    fig=figure(graph|graph)
    before=calls[]
    original=plots_of(fig,Lines)
    window[]=(.5,2.5)
    colour[]=:blue
    @test calls[] == before
    @test plots_of(fig,Lines) == original
    @test all(p->p.color[]==RGBAf(0,0,1,1),original)
    @test all(ax->ax.limits[][1]==(.5,2.5),axes_of(fig))
    @test size(colorbuffer(fig),1)>0
end

@testset "Reactive children and empty grid cells" begin
    rows=(x=[1.,2.],y=[2.,3.])
    base=data(rows)*mapping(:x,:y)*visual(Lines)
    calls=Ref(0)
    sibling=data(rows)*mapping(:x,:y)*transformation(p->(calls[]+=1;p))*visual(Scatter)
    child=Observable{Any}(base)
    fig=figure([base child; nothing sibling])
    @test length(axes_of(fig)) == 3
    initial=calls[]
    child[]=data((x=[1.,2.],y=[7.,9.]))*mapping(:x,:y)*visual(Lines)
    @test any(p->last.(p[1][])≈[7,9],plots_of(fig,Lines))
    @test calls[] == initial
    child[]=nothing
    @test length(axes_of(fig)) == 2
    @test calls[] == initial
    child[]=base
    @test length(axes_of(fig)) == 3
    @test calls[] == initial
    dynamic=Observable(rows)
    child[]=data(dynamic)*mapping(:x,:y)*visual(Lines)
    GC.gc()
    dynamic[]=(x=[1.,2.],y=[11.,13.])
    @test any(p->last.(p[1][])≈[11,13],plots_of(fig,Lines))
    child[]=base
    dynamic[]=(x=[1.,2.],y=[21.,23.])
    @test !any(p->last.(p[1][])≈[21,23],plots_of(fig,Lines))
    @test calls[] == initial

    live=Observable(base)
    @test length(axes_of(figure(live|base))) == 2
    @test length(axes_of(figure(live/base))) == 2
    @test length(axes_of(figure([base live; live base]))) == 4
    @test length(axes_of(figure(nothing|base))) == 1
    @test length(axes_of(figure(base/nothing))) == 1
    @test_throws ArgumentError figure([1 2;3 4])
    @test hcat(Observable(1),Observable(2)) isa Matrix
    @test vcat(Observable(1),Observable(2)) isa Vector
end

@testset "Existing author syntax with reactive data" begin
    rows=Observable((x=[1.,1.,2.,2.],y=[1.,3.,2.,4.]))
    selected=Observable(:y)
    declaration=@plot data(rows)*mapping(:x,selected) begin
        result=aggregate(sum)
        mapping(result.x,result.sum)*visual(Scatter)
    end
    fig=figure(declaration)
    @test only(plots_of(fig,Scatter))[1][] ≈ Point2d[(1.,4.),(2.,6.)]
    rows[]=(x=[1.,1.,2.,2.],y=[2.,6.,4.,8.])
    @test only(plots_of(fig,Scatter))[1][] ≈ Point2d[(1.,8.),(2.,12.)]

    curve(x;a,b)=a*x+b
    measurements=Observable((x=[1.,2.,3.,4.],y=[3.,5.,7.,9.]))
    fitted=@plot data(measurements)*mapping(:x,:y) begin
        result=fit(curve,(a=1.,b=1.))
        result*visual(Lines)
    end
    fig=figure(fitted)
    @test first(only(plots_of(fig,Lines))[1][]) ≈ Point2d(1,3)
    measurements[]=(x=[1.,2.,3.,4.],y=[4.,7.,10.,13.])
    @test last(only(plots_of(fig,Lines))[1][]) ≈ Point2d(4,13)

    header=data(rows)*mapping(:x,:y)
    fig=figure(header(visual(Lines),visual(Scatter)))
    rows[]=(x=[1.,1.,2.,2.],y=[3.,9.,6.,12.])
    @test last.(only(plots_of(fig,Lines))[1][]) ≈ [3,9,6,12]
    @test last.(only(plots_of(fig,Scatter))[1][]) ≈ [3,9,6,12]
end

@testset "Live coordinates survive other panel changes" begin
    rows=(x=[1.,2.,3.],y=[2.,3.,4.])
    window=Observable((0.,4.))
    sibling=data(rows)*mapping(:x,:y)*visual(Lines)+coord(x=(limits=window,))
    child=Observable{Any}(data(rows)*mapping(:x,:y)*visual(Scatter))
    fig=figure(child|sibling)
    axis=axes_of(fig)[2]
    line=only(plots_of(fig,Lines))
    window[]=(.5,2.5)
    child[]=nothing
    child[]=data(rows)*mapping(:x,:y)*visual(Scatter)
    @test axis in axes_of(fig)
    @test axis.limits[][1] == (.5,2.5)
    @test only(plots_of(fig,Lines)) === line
    @test length(axes_of(figure(sibling|Observable{Any}(nothing)))) == 1
    @test length(axes_of(figure(Observable{Any}(nothing)/sibling))) == 1

    empty=figure([nothing sibling];figure_kw=(size=(800,400),))
    colorbuffer(empty)
    viewport=only(axes_of(empty)).scene.viewport[]
    @test viewport.origin[1] > 400
end

@testset "Native palette indices survive compilation" begin
    rows = Observable((x = [1., 2., 3.], y = [2., 3., 4.]))
    opacity = Observable(1.0)
    graph = data(rows) * mapping(:x, :y) * visual(Lines; color = Cycled(2), alpha = opacity)
    palette = [Makie.to_color(:red), Makie.to_color(:green), Makie.to_color(:blue)]
    fig = Makie.with_theme(palette = (color = palette,)) do
        figure(graph)
    end
    line = only(plots_of(fig, Lines))
    @test line.color[] == palette[2]
    @test size(colorbuffer(fig), 1) > 0
    rows[] = (x = [1., 2., 3.], y = [4., 5., 6.])
    @test only(plots_of(fig, Lines)) === line
    @test line.color[] == palette[2]
    opacity[] = 0.5
    @test line.alpha[] == 0.5

    index = Observable(Cycled(1))
    live = figure(data(rows) * mapping(:x, :y) * visual(Lines; color = index))
    native_palette = Makie.to_value(Makie.current_default_theme().palette.color)
    native_line = only(plots_of(live, Lines))
    @test native_line.color[] == native_palette[1]
    index[] = Cycled(3)
    @test native_line.color[] == native_palette[3]
    @test size(colorbuffer(live), 1) > 0

    flexible_color = Observable{Any}(:red)
    flexible = figure(data(rows) * mapping(:x, :y) * visual(Lines; color = flexible_color))
    flexible_color[] = Cycled(2)
    @test only(plots_of(flexible, Lines)).color[] == native_palette[2]

    styled = figure(data((x = [1., 2.], y = [2., 3.])) * mapping(:x, :y) *
        visual(Lines; cycle = [:color, :linestyle], color = Cycled(2)))
    @test only(plots_of(styled, Lines)).cycle[] !== nothing
end

@testset "Coordinates exclude labels and appearance" begin
    @test_throws ArgumentError coord(x = (label = "Time",))
    @test_throws ArgumentError coord(y = (ticklabelsvisible = false,))
    @test_throws ArgumentError coord(title = "Signal")
    graph = data((x = [1., 2.], y = [2., 3.])) *
        mapping(:x => "Time", :y => "Current") * visual(Lines) +
        coord(x = (limits = (0., 4.),)) +
        plot_theme(Axis = (ylabelvisible = false,))
    axis = only(axes_of(figure(graph)))
    @test axis.xlabel[] == "Time"
    @test axis.ylabel[] == "Current"
    @test axis.ylabelvisible[] == false
end

@testset "Histogram closure reaches the actual statistic" begin
    rows = (current = [0., 1., 2., 3.],)
    edges = [0., 1., 2., 3.]
    for closed in (:left, :right)
        expected = Grafico.StatsBase.fit(Grafico.StatsBase.Histogram, rows.current, edges; closed)
        graph = data(rows) * mapping(:current) *
            Grafico.histogram(bins = edges, datalimits = (0., 3.), closed = closed)
        hist = only(plots_of(figure(graph), BarPlot))
        @test last.(hist[1][]) == expected.weights
        weighted = data((current = rows.current, weight = [1., 2., 4., 8.])) *
            mapping(:current; weights = :weight) *
            Grafico.histogram(bins = edges, datalimits = (0., 3.), closed = closed)
        weighted_expected = Grafico.StatsBase.fit(Grafico.StatsBase.Histogram, rows.current,
            Grafico.StatsBase.weights([1., 2., 4., 8.]), edges; closed)
        @test last.(only(plots_of(figure(weighted), BarPlot))[1][]) == weighted_expected.weights
    end
end

include("test_motion.jl")

@testset "Y-series selectors survive reactive macro inputs" begin
    rows = Observable((x = [0., 1., 2.], a = [1., 2., 3.], b = [4., 5., 6.]))
    graph = @plot data(rows) * mapping(; x = :x, y = :a, y2 = :b, color = ydims()) begin
        visual(Lines)
    end
    fig = figure(graph)
    lines = plots_of(fig, Lines)
    @test length(lines) == 2
    @test [last.(line[1][]) for line in lines] == [[1., 2., 3.], [4., 5., 6.]]
    rows[] = (x = [0., 1., 2.], a = [3., 6., 9.], b = [2., 4., 8.])
    @test plots_of(fig, Lines) == lines
    @test [last.(line[1][]) for line in lines] == [[3., 6., 9.], [2., 4., 8.]]
end
