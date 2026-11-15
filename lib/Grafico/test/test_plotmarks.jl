function plots_of_frame(frame, type)
    found = Any[]
    function visit(plot)
        plot isa type && push!(found, plot)
        foreach(visit, plot.plots)
    end
    for axis in frame_axes(frame), plot in axis.scene.plots
        visit(plot)
    end
    found
end

frame_axes(frame) = [block for (_, (block, _)) in first(frame.layouts) if block isa Axis]
frames_of(fig) = filter(block -> block isa Grafico._GraficoPlotFrame, fig.content)

@testset "Complete charts retain native plots during placement and zoom" begin
    rows = Observable((x = [0., .5, 1.], y = [0., 1., 0.]))
    calls = Ref(0)
    graph = data(rows) * mapping(:x => "Time", :y => "Signal") *
        transformation(p -> (calls[] += 1; p)) * visual(Lines)
    window = Observable((0., 1.))
    placement = Observable(T(0, 0) * U(1))
    detail = mark(graph + coord(x = (limits = window,)))
    fig = figure(mark(graph) + placement * detail; figure_kw = (size = (700, 450),))
    frames = frames_of(fig)
    native_axes = only.(frame_axes.(frames))
    native_plots = [copy(axis.scene.plots) for axis in native_axes]
    before = calls[]
    story = Grafico.plan(sequence(
        to(window => (.2, .6); duration = 1),
        to(placement => T(.5, .5) * U(.45); duration = 1),
    ))
    Grafico.seek!(story, 1.5)
    @test placement[].tx ≈ .25
    @test placement[].a ≈ .725
    @test native_axes[2].limits[][1] == (.2, .6)
    Grafico.seek!(story, 2)
    @test calls[] == before
    @test only.(frame_axes.(frames)) == native_axes
    @test [axis.scene.plots for axis in native_axes] == native_plots
    viewport = native_axes[2].scene.viewport[]
    @test viewport.widths[1] < native_axes[1].scene.viewport[].widths[1]
    resize!(fig, 1000, 600)
    colorbuffer(fig)
    @test native_axes[2].scene.viewport[].widths[1] > viewport.widths[1]
    Grafico.seek!(story, 0)
    @test native_axes[2].limits[][1] == (0., 1.)
    @test only.(frame_axes.(frames)) == native_axes
    rows[] = (x = [0., .5, 1.], y = [1., 2., 1.])
    @test last.(only(plots_of_frame(frames[2], Lines))[1][]) ≈ [1, 2, 1]
end

@testset "Placed chart and ordinary host keep separate guide ownership" begin
    graph = data((x = [0., .5, 1.], y = [0., 1., 0.])) *
        mapping(:x, :y) * visual(Scatter)
    placed = T(.5, .5) * U(.45) * mark(graph)
    fig = figure([graph graph + placed]; layout = (colgaps = 0, linkyaxes = :rowwise,))
    host_axes = axes_of(fig)
    @test length(host_axes) == 2
    @test host_axes[1].yticklabelsvisible[]
    @test !host_axes[2].yticklabelsvisible[]
    @test only(frame_axes(only(frames_of(fig)))).yticklabelsvisible[]

    diagram = figure(beside(mark(graph), mark(graph)))
    areas = [only(frame_axes(frame)).scene.viewport[] for frame in frames_of(diagram)]
    @test length(areas) == 2
    @test areas[1].origin[1] + areas[1].widths[1] < areas[2].origin[1]
    @test areas[2].origin[1] + areas[2].widths[1] <= diagram.scene.viewport[].widths[1]
end

@testset "Deleting a placed chart releases native and analysis bindings" begin
    rows = Observable((x = [0., 1.], y = [0., 1.]))
    window = Observable((0., 1.))
    placement = Observable(T(.1, .1) * U(.8))
    calls = Ref(0)
    graph = data(rows) * mapping(:x, :y) * transformation(p -> (calls[] += 1; p)) *
        visual(Lines) + coord(x = (limits = window,))
    listeners = length(Makie.Observables.listeners(placement))
    fig = figure(placement * mark(graph))
    frame = only(frames_of(fig))
    axis = only(frame_axes(frame))
    delete!(frame)
    before = calls[]
    rows[] = (x = [0., 1.], y = [2., 3.])
    placement[] = T(.5, .5) * U(.4)
    window[] = (.2, .4)
    @test calls[] == before
    @test isempty(frame.blockscene.children)
    @test isempty(frame.blockscene.deregister_callbacks)
    @test length(Makie.Observables.listeners(placement)) == listeners
    @test axis.parent === nothing
    @test axis.limits[][1] == (0., 1.)
end

@testset "Complete chart placement reports unsupported transforms" begin
    graph = data((x = [0., 1.], y = [0., 1.])) * mapping(:x, :y) * visual(Lines)
    @test_throws ArgumentError figure(R(.2) * mark(graph))
    @test_throws ArgumentError figure(U(-1) * mark(graph))
    @test_throws ArgumentError figure(mark(Makie.SpecApi.GridLayout([(1, 1) => Makie.SpecApi.Axis3()])))
    primitive = T(.5, .5) * (CircleMark(r=.2) + T(.2, 0) * RectMark(w=.2, h=.2))
    @test boundingbox(primitive).xmin ≈ .3
    @test colorbuffer(figure(primitive)) isa AbstractArray
end

@testset "Empty chart sources stay empty and chart templates accept input" begin
    graph = data((x=[0., 1.], y=[0., 1.])) * mapping(:x, :y) * visual(Lines)
    source = Observable{Any}(nothing)
    fig = figure(mark(graph) + T(.5, .5) * U(.4) * mark(source))
    frame = frames_of(fig)[2]
    backdrop = only(frame.blockscene.plots)
    @test !backdrop.visible[]
    source[] = graph
    @test backdrop.visible[]
    axis = only(frame_axes(frame))
    source[] = nothing
    @test !backdrop.visible[]
    @test !axis.blockscene.visible[]
    source[] = graph
    @test axis.blockscene.visible[]
    @test only(frame_axes(frame)) === axis

    template = @plot mapping(:x, :y) begin
        visual(Scatter)
    end
    inputs = (x = [0., 1.], y = [2., 3.])
    templated = figure(mark(template), inputs)
    native = only(plots_of_frame(only(frames_of(templated)), Scatter))
    @test native[1][] ≈ Point2d[(0, 2), (1, 3)]
end
