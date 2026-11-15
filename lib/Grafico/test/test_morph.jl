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

@testset "Default fades for empty views and changed panel layouts" begin
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
end # module GraficoMorphChecks
