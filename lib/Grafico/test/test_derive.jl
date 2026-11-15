@testset "Observations arrive before their histogram weight is counted" begin
    for closed in (:left, :right)
        time = collect(0.:4.)
        current = [0., .2, .5, .8, 1.]
        weights = [1., 2., 3., 4., 5.]
        rows = data((; time, current, weights))
        source = rows * mapping(:time, :current) * visual(Lines)
        destination = rows * mapping(:current; weights = :weights) *
            Grafico.histogram(; bins = [-.1, .25, .5, .75, 1.1], closed, direction = :x)
        view = Observable{Any}(nothing)
        fig = figure([view source])
        source_axis = only(axes_of(fig))
        original_plots = length(source_axis.scene.plots)
        original_overlays = length(fig.scene.plots)
        planned = Grafico.plan(to(view => destination; from = source, duration = 1, ease = identity))
        @test view[] === nothing
        for (time, weight) in ((.01, 0.), (.21, 1.), (.41, 3.), (.81, 10.), (.41, 3.))
            Grafico.seek!(planned, time)
            bars = only(plots_of(fig, BarPlot))
            @test sum(last, bars[1][]) ≈ weight
            @test source_axis in axes_of(fig)
        end
        middle = colorbuffer(fig)
        Grafico.seek!(planned, .7)
        Grafico.seek!(planned, .41)
        @test colorbuffer(fig) == middle
        Grafico.seek!(planned, 1)
        @test view[] === destination
        @test sum(last, only(plots_of(fig, BarPlot))[1][]) ≈ sum(weights)
        @test length(source_axis.scene.plots) == original_plots
        @test length(fig.scene.plots) == original_overlays
        Grafico.seek!(planned, .41)
        Grafico.seek!(planned, 0)
        @test sum(last, only(plots_of(fig, BarPlot))[1][]) == 0
        Grafico.seek!(planned, 1)
        @test length(source_axis.scene.plots) == original_plots
        @test length(fig.scene.plots) == original_overlays
    end
end

@testset "Ordinary views identify the two readings of a coordinate plot" begin
    time = collect(0.:5.)
    current = [2., 2., 1., 3., 2., 1.]
    source = data((; time, current)) * mapping(:time, :current) * visual(Lines)
    destination = data((x = @view(current[1:end-2]), y = @view(current[3:end]))) *
        mapping(:x => "First", :y => "Second") * visual(Scatter)
    view = Observable{Any}(nothing)
    fig = figure([source view])
    source_axis = only(axes_of(fig))
    visits = Tuple{Point2d,Point2d,Float64}[]
    route(a, b, u) = (push!(visits, (a, b, u)); (1-u)*a + u*b)
    planned = Grafico.plan(to(view => destination; from = source, duration = 4,
                             ease = identity, path = route))
    for (time, arrived) in ((.3, 0), (1.3, 1), (2.3, 2), (3.3, 3), (1.3, 1))
        Grafico.seek!(planned, time)
        target = only(filter(axis -> axis.xlabel[] == "First", axes_of(fig)))
        dots = only(filter(plot -> plot isa Scatter, target.scene.plots))
        @test length(dots[1][]) == arrived
        @test source_axis in axes_of(fig)
    end
    @test !isempty(visits)
    @test all(visit -> 0 <= last(visit) <= 1, visits)
    @test all(visit -> all(isfinite, visit[1]) && all(isfinite, visit[2]), visits)
    @test all(visit -> all(x -> -.05 <= x <= 1.05, visit[1]), visits)
    Grafico.seek!(planned, 4)
    target = only(filter(axis -> axis.xlabel[] == "First", axes_of(fig)))
    dots = only(filter(plot -> plot isa Scatter, target.scene.plots))
    @test dots[1][] == Point2d.(current[1:end-2], current[3:end])
    @test isempty(filter(plot -> plot isa Scatter, source_axis.scene.plots))
end

@testset "Derived source values are coherent before lift notifications" begin
    amount = Observable(0.)
    readings = lift(fraction -> [1., 2., 3., 4.] .- fraction, amount)
    source = data((time = collect(0.:3.), current = readings)) *
        mapping(:time, :current) * visual(Lines)
    pairs = lift(values -> (x = @view(values[1:end-1]), y = @view(values[2:end])), readings)
    destination = data(pairs) * mapping(:x => "First", :y) * visual(Scatter)
    view = Observable{Any}(nothing)
    fig = figure([source view])
    # The destination is notified first. Preparation must still see the new amount
    # for both declarations, including the shared array produced by lift.
    planned = Grafico.plan(together(
        to(view => destination; from = source, duration = 1, ease = identity),
        to(amount => .5; duration = 0),
    ))
    Grafico.seek!(planned, .5)
    target = only(filter(axis -> axis.xlabel[] == "First", axes_of(fig)))
    dots = only(filter(plot -> plot isa Scatter, target.scene.plots))
    @test first(dots[1][]) == Point2d(.5, 1.5)
    Grafico.seek!(planned, 1)
    @test amount[] == .5
    @test view[] === destination
end

@testset "Derivation authoring errors are reported before recording" begin
    source = data((x = [1., 2.], y = [3., 4.])) * mapping(:x, :y) * visual(Scatter)
    @test_throws ArgumentError to(Observable(source) => source; from = source)
    @test_throws ArgumentError to(Observable(0.) => 1.; from = source)
    @test_throws ArgumentError to(Observable(0.) => 1.; path = identity)
    @test Grafico.duration(to(Observable{Any}(nothing) => source; from = source)) == 6
end

@testset "Derivations capture data at their logical start" begin
    amount = Observable(0.)
    readings = lift(fraction -> [1., 2., 3., 4.] .- fraction, amount)
    source = data((time = collect(0.:3.), current = readings)) *
        mapping(:time, :current) * visual(Lines)
    pairs = lift(values -> (x = @view(values[1:end-1]), y = @view(values[2:end])), readings)
    destination = data(pairs) * mapping(:x => "First", :y) * visual(Scatter)
    view = Observable{Any}(nothing)
    fig = figure([source view])
    planned = Grafico.plan(together(
        to(view => destination; from = source, duration = 1, ease = identity),
        to(amount => .5; duration = 1, ease = identity),
    ))
    # Visit the middle first: observations still come from the clip's beginning.
    Grafico.seek!(planned, .5)
    target = only(filter(axis -> axis.xlabel[] == "First", axes_of(fig)))
    dots = only(filter(plot -> plot isa Scatter, target.scene.plots))
    @test first(dots[1][]) == Point2d(1., 2.)
    middle = colorbuffer(fig)
    Grafico.seek!(planned, 0)
    Grafico.seek!(planned, .5)
    @test colorbuffer(fig) == middle
end

@testset "Captured observations retain shared array parents without aliasing author data" begin
    time = collect(0.:3.)
    current = [1., 2., 3., 4.]
    source = data((; time, current)) * mapping(:time, :current) * visual(Lines)
    destination = data((x = @view(current[1:end-1]), y = @view(current[2:end]))) *
        mapping(:x => "First", :y) * visual(Scatter)
    view = Observable{Any}(nothing)
    fig = figure([source view])
    planned = Grafico.plan(to(view => destination; from = source, duration = 1, ease = identity))
    current .+= 100
    Grafico.seek!(planned, .5)
    target = only(filter(axis -> axis.xlabel[] == "First", axes_of(fig)))
    dots = only(filter(plot -> plot isa Scatter, target.scene.plots))
    @test first(dots[1][]) == Point2d(1., 2.)
    @test current == [101., 102., 103., 104.]
end
