module GraficoMorphChecks
using Test, Grafico, CairoMakie
const S = Makie.SpecApi

function visible_plots(axis, kind)
    result=Any[]
    function visit(plot)
        plot isa kind && plot.visible[] && push!(result,plot)
        foreach(visit,plot.plots)
    end
    foreach(visit,axis.scene.plots)
    result
end

@testset "Native palette, defaults, stable axes, and reversible curve morphs" begin
    x=collect(range(-2,2;length=41))
    source=data((;x,y=sin.(3x)))*mapping(:x,:y)*visual(Lines;color=Cycled(1))
    target=data((;x,y=.5cos.(5x)))*mapping(:x,:y)*visual(Lines;color=Cycled(4),linewidth=5)
    view=Observable{Any}(source)
    fig=figure(view;figure_kw=(size=(1000,550),linewidth=3,
        palette=(color=[:navy,:teal,:plum,:tomato],),))
    axis=only(filter(block->block isa Axis,fig.content))
    initial=only(visible_plots(axis,Lines))
    original_width=initial.linewidth[]
    original_color=initial.color[]
    plan=Grafico.plan(to(view=>target;duration=2,ease=identity))
    @test view[]===source
    Grafico.seek!(plan,1)
    @test only(filter(block->block isa Axis,fig.content))===axis
    line=only(visible_plots(axis,Lines))
    @test last.(line[1][]) ≈ .5sin.(3x) .+ .25cos.(5x)
    @test line.linewidth[] ≈ (original_width+5)/2
    expected=(collect(Tuple(RGBAf(original_color)))+collect(Tuple(RGBAf(Makie.to_color(:tomato)))))/2
    @test collect(Tuple(RGBAf(line.color[])))≈expected
    image=copy(colorbuffer(fig))
    for time in (1.7,.3,1.)
        Grafico.seek!(plan,time)
        @test only(visible_plots(axis,Lines))===line
    end
    @test colorbuffer(fig)==image
    Grafico.seek!(plan,2)
    @test view[]===target
    @test only(filter(block->block isa Axis,fig.content))===axis
    @test length(axis.scene.plots)==1
    @test only(visible_plots(axis,Lines)).linewidth[]==5
    Grafico.seek!(plan,1)
    @test colorbuffer(fig)==image
end

@testset "Native image matrices and 3D surface geometry" begin
    x,y=collect(1.:4.),collect(1.:5.)
    first_values=[sin(a)*cos(b) for a in x,b in y]
    last_values=[.5cos(a)*sin(b) for a in x,b in y]
    for (kind,blocktype) in ((Heatmap,Axis),(Surface,Axis3))
        symbol=kind===Heatmap ? :Heatmap : :Surface
        axis_symbol=blocktype===Axis ? :Axis : :Axis3
        source=S.GridLayout([(1,1)=>Makie.BlockSpec(axis_symbol,Dict{Symbol,Any}(),
            [Makie.PlotSpec(symbol,x,y,first_values)])])
        destination=S.GridLayout([(1,1)=>Makie.BlockSpec(axis_symbol,Dict{Symbol,Any}(),
            [Makie.PlotSpec(symbol,x,y,last_values)])])
        view=Observable{Any}(source)
        fig=figure(view)
        axis=only(filter(block->block isa blocktype,fig.content))
        plan=Grafico.plan(to(view=>destination;duration=2,ease=identity))
        Grafico.seek!(plan,1)
        @test axis in fig.content
        plot=only(visible_plots(axis,kind))
        @test plot[3][]≈(first_values+last_values)/2
        snapshot=copy(colorbuffer(fig))
        Grafico.seek!(plan,.4)
        Grafico.seek!(plan,1)
        @test colorbuffer(fig)==snapshot
        Grafico.seek!(plan,2)
        @test axis in fig.content
        @test length(visible_plots(axis,kind))==1
    end
end

@testset "Point-count changes fade and owned plots are removed" begin
    source=data((x=[1.,2.,3.],y=[2.,4.,3.]))*mapping(:x,:y)*visual(Scatter)
    target=data((x=[1.,2.,3.,4.,5.],y=[2.,4.,3.,5.,4.]))*mapping(:x,:y)*visual(Scatter)
    view=Observable{Any}(source)
    fig=figure(view)
    axis=only(filter(block->block isa Axis,fig.content))
    plan=Grafico.plan(to(view=>target;duration=2,ease=identity))
    Grafico.seek!(plan,1)
    plots=visible_plots(axis,Scatter)
    @test length(plots)==2
    @test sort([length(plot[1][]) for plot in plots])==[3,5]
    @test all(plot->plot.alpha[]==.5,plots)
    Grafico.seek!(plan,2)
    @test length(axis.scene.plots)==1
    @test length(only(visible_plots(axis,Scatter))[1][])==5
end



@testset "Continuous coordinates from integer measurements" begin
    source = data((x=[1,2,3], y=[1,3,2])) * mapping(:x,:y) * visual(Lines)
    target = data((x=[1,2,3], y=[2,4,3])) * mapping(:x,:y) * visual(Lines)
    view = Observable{Any}(source)
    fig = figure(view)
    axis = only(filter(block -> block isa Axis, fig.content))
    plan = Grafico.plan(to(view => target; duration=2, ease=identity))
    Grafico.seek!(plan, .5)
    @test last.(only(visible_plots(axis,Lines))[1][]) ≈ [1.25,3.25,2.25]
end

@testset "Logical clip starts, frozen rows, and reactive endpoints" begin
    x = [1.,2.,3.]
    amplitude = Observable(1.)
    rows = lift(a -> (; x, y=a .* [1.,3.,2.]), amplitude)
    source = data(rows) * mapping(:x,:y) * visual(Lines)
    target = data(rows) * mapping(:x,:y => (y -> -y)) * visual(Lines)
    view = Observable{Any}(source)
    fig = figure(view)
    axis = only(filter(block -> block isa Axis, fig.content))
    plan = Grafico.plan(sequence(to(amplitude => 2.; duration=1),
                                to(view => target; duration=2, ease=identity)))
    x[1] = 10.
    # The first seek is inside the second clip; earlier frames need not run.
    Grafico.seek!(plan, 1.5)
    @test amplitude[] == 2.
    @test only(visible_plots(axis,Lines))[1][] ≈ Point2d[(1,1),(2,3),(3,2)]
    Grafico.seek!(plan, 3)
    amplitude[] = 4.
    @test last.(only(visible_plots(axis,Lines))[1][]) ≈ [-4.,-12.,-8.]
    @test_throws ArgumentError Grafico.plan(to(Observable(source) => target))
end

@testset "Frozen native specifications and stable mesh topology" begin
    S = Makie.SpecApi
    positions = Point3f[(0,0,0), (1,0,0), (0,1,0)]
    target_positions = positions .+ Ref(Vec3f(0,0,1))
    faces = [Makie.GeometryBasics.TriangleFace(1,2,3)]
    chart(values) = S.GridLayout([(1,1) => S.Axis3(plots=[S.Mesh(values,faces)])])
    view = Observable{Any}(chart(positions))
    fig = figure(view)
    axis = only(filter(block -> block isa Axis3, fig.content))
    plan = Grafico.plan(to(view => chart(target_positions); duration=2, ease=identity))
    positions[1] = Point3f(50,50,50)
    Grafico.seek!(plan, 1)
    mesh = only(visible_plots(axis,Mesh))
    @test Makie.GeometryBasics.coordinates(mesh[1][]) ≈
        Point3f[(0,0,.5), (1,0,.5), (0,1,.5)]
    @test Makie.GeometryBasics.faces(mesh[1][]) == faces
end

@testset "Empty views and changed panel layouts remain reversible" begin
    source = data((x=[1.,2.,3.],y=[2.,3.,4.])) * mapping(:x,:y) * visual(Lines)
    points = data((x=[1.,2.,3.],y=[4.,2.,3.])) * mapping(:x,:y) * visual(Scatter)
    for (a,b) in ((nothing,source),(source,nothing),(source,source | points))
        view = Observable{Any}(a)
        fig = figure(view)
        plan = Grafico.plan(to(view => b; duration=2, ease=identity))
        Grafico.seek!(plan,1)
        image = copy(colorbuffer(fig))
        @test any(color -> minimum(Tuple(RGBf(color))) < .9, image)
        for time in (2.,0.,.4,1.)
            Grafico.seek!(plan,time)
        end
        @test colorbuffer(fig) == image
        Grafico.seek!(plan,2)
        @test view[] === b
    end
end
@testset "Intermediate SpecAPI snapshots without a figure" begin
    source = data((x=[1.,2.,3.], y=[1.,3.,2.])) * mapping(:x,:y) * visual(Lines)
    target = data((x=[1.,2.,3.], y=[2.,1.,4.])) * mapping(:x,:y) * visual(Lines)
    view = Observable{Any}(source)
    plan = Grafico.plan(to(view => target; duration=2, ease=identity))
    Grafico.seek!(plan,1)
    specification = spec(view)
    @test specification isa Makie.GridLayoutSpec
    fig = Figure()
    Makie.plot(fig[1,1],specification)
    axis = only(filter(block -> block isa Axis,fig.content))
    @test last.(only(visible_plots(axis,Lines))[1][]) ≈ [1.5,2.,3.]
    @test size(colorbuffer(fig),1) > 0
end

@testset "Returned figures are whole-chart motion targets" begin
    rows = Observable((x=[1.,2.,3.],y=[2.,4.,3.]))
    source = data(rows) * mapping(:x,:y) * visual(Lines)
    target = data((x=[1.,2.,3.],y=[3.,2.,4.])) * mapping(:x,:y) * visual(Lines)
    fig = figure(source)
    @test fig isa Figure
    axis = only(filter(block -> block isa Axis,fig.content))
    rows[] = (x=[1.,2.,3.],y=[4.,8.,6.])
    @test last.(only(visible_plots(axis,Lines))[1][]) ≈ [4.,8.,6.]
    plan = Grafico.plan(sequence(to(fig => target; duration=2,ease=identity),
                                to(fig => source; duration=2,ease=identity)))
    Grafico.seek!(plan,1)
    @test last.(only(visible_plots(axis,Lines))[1][]) ≈ [3.5,5.,5.]
    Grafico.seek!(plan,4)
    @test last.(only(visible_plots(axis,Lines))[1][]) ≈ [4.,8.,6.]
    @test_throws ArgumentError to(Figure() => target)
    @test_throws ArgumentError to(fig => target,fig => source)
end

@testset "Panel additions, removals and reordered layouts retain geometry" begin
    x = collect(range(-2,2;length=31))
    curve = data((;x,y=sin.(3x))) * mapping(:x,:y) * visual(Lines;color=Cycled(1))
    dots = data((;x,y=cos.(3x))) * mapping(:x,:y) * visual(Scatter;color=Cycled(2))
    for (source,target) in ((curve,curve | dots),(curve,curve / dots),
                             (curve | dots,dots | curve),(curve | dots,curve))
        fig = figure(source;figure_kw=(size=(960,540),))
        axes = filter(block -> block isa Axis,fig.content)
        curve_axis = only(filter(axis -> !isempty(visible_plots(axis,Lines)),axes))
        start = curve_axis.layoutobservables.computedbbox[]
        fontsize = curve_axis.xlabelsize[]
        plan = Grafico.plan(to(fig => target;duration=2,ease=identity))
        Grafico.seek!(plan,.5)
        line = only(visible_plots(curve_axis,Lines))
        @test line.alpha[] == 1
        @test curve_axis.xlabelsize[] == fontsize
        Grafico.seek!(plan,1)
        midpoint = curve_axis.layoutobservables.computedbbox[]
        @test midpoint != start
        @test only(visible_plots(curve_axis,Lines)) === line
        snapshot = copy(colorbuffer(fig))
        for time in (1.8,2.,0.,.3,1.)
            Grafico.seek!(plan,time)
        end
        @test colorbuffer(fig) == snapshot
        Grafico.seek!(plan,2)
        @test length(filter(block -> block isa Axis,fig.content)) == (target === curve ? 1 : 2)
    end
end

@testset "A composed child morph survives a reactive neighbour update" begin
    x = collect(1.:7.)
    curve = data((; x, y = sin.(x))) * mapping(:x, :y) * visual(Lines)
    dots = data((; x, y = cos.(x))) * mapping(:x, :y) * visual(Scatter)
    rows = Observable((; x, y = cos.(x)))
    neighbour_plot = data(rows) * mapping(:x, :y) * visual(Scatter)
    child = Observable{Any}(curve)
    fig = figure(child | neighbour_plot; figure_kw = (size = (1100,550),))
    curve_axis, neighbour = filter(block -> block isa Axis, fig.content)
    neighbour_box = neighbour.layoutobservables.computedbbox[]

    plan = Grafico.plan(to(child => curve / dots; duration = 2, ease = identity))
    Grafico.seek!(plan, 1)
    @test neighbour.layoutobservables.computedbbox[] == neighbour_box
    @test length(filter(block -> block isa Axis, fig.content)) == 3
    curve_box = curve_axis.layoutobservables.computedbbox[]
    line = only(visible_plots(curve_axis, Lines))

    rows[] = (; x, y = reverse(cos.(x)))
    @test last.(only(visible_plots(neighbour, Scatter))[1][]) ≈ rows[].y
    @test neighbour.layoutobservables.computedbbox[] == neighbour_box
    @test curve_axis.layoutobservables.computedbbox[] == curve_box
    @test only(visible_plots(curve_axis, Lines)) === line

    snapshot = copy(colorbuffer(fig))
    Grafico.seek!(plan, 1.8)
    Grafico.seek!(plan, 1)
    @test colorbuffer(fig) == snapshot
    Grafico.seek!(plan, 2)
    Grafico.seek!(plan, 1)
    @test colorbuffer(fig) == snapshot
end

@testset "Native resize and 3D layout snapshots" begin
    x,y = collect(1.:4.),collect(1.:5.)
    values = [sin(a)*cos(b) for a in x,b in y]
    source = S.GridLayout([(1,1)=>S.Axis3(plots=[S.Surface(x,y,values)])])
    target = S.GridLayout([(1,1)=>S.Axis3(plots=[S.Surface(x,y,values)]),
                           (1,2)=>S.Axis3(plots=[S.Surface(x,y,-values)])])
    fig = figure(source;figure_kw=(size=(1000,500),))
    axis = only(filter(block -> block isa Axis3,fig.content))
    initial_width = axis.layoutobservables.computedbbox[].widths[1]
    plan = Grafico.plan(to(fig => target;duration=2,ease=identity))
    Grafico.seek!(plan,1)
    @test axis in fig.content
    @test axis.layoutobservables.computedbbox[].widths[1] < initial_width
    before = axis.layoutobservables.computedbbox[]
    resize!(fig,1280,640)
    @test axis.layoutobservables.computedbbox[].widths[1] > before.widths[1]
    image = copy(colorbuffer(fig))
    Grafico.seek!(plan,2)
    Grafico.seek!(plan,1)
    @test colorbuffer(fig) == image

    view = Observable{Any}(source)
    snapshot_plan = Grafico.plan(to(view => target;duration=2,ease=identity))
    Grafico.seek!(snapshot_plan,1)
    snapshot = Figure()
    Makie.plot(snapshot[1,1],spec(view))
    @test any(color -> minimum(Tuple(RGBf(color))) < .9,colorbuffer(snapshot))
end

@testset "Unified figure compilation retains guides and native options" begin
    graph = data((x=[1.,2.,3.],y=[2.,4.,3.],c=[1.,3.,2.])) *
        mapping(:x,:y;color=:c) * visual(Scatter)
    fig = figure(graph;figure=(size=(900,500),))
    @test length(filter(block -> block isa Makie.Colorbar,fig.content)) == 1
    @test Tuple(Makie.widths(fig.scene.viewport[])) == (900,500)
    hidden = figure(graph;colorbar=(show=false,))
    @test isempty(filter(block -> block isa Makie.Colorbar,hidden.content))
end

end # module GraficoMorphChecks
