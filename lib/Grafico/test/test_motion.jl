@testset "Motion authoring and repeatable seeking" begin
    value = Observable(2.0)
    notifications = Ref(0)
    listener = on(value) do _
        notifications[] += 1
    end
    motion = sequence(
        to(value => 10.0; duration = 2, ease = identity),
        hold(0.5),
        to(value => -5.0; duration = 3, ease = identity),
        to(value => 7.0; duration = 1, ease = identity),
    )
    planned = Grafico.plan(motion)
    @test value[] == 2.0
    @test notifications[] == 0
    @test Grafico.duration(planned) == Grafico.duration(motion) == 6.5
    for (time, expected) in ((4.3, 1.0), (0.3, 3.2), (5.75, -2.0),
                             (2.2, 10.0), (6.5, 7.0), (-3, 2.0), (50, 7.0))
        @test Grafico.seek!(planned, time) === planned
        @test value[] ≈ expected
        @test planned.time[] == clamp(time, 0, 6.5)
    end
    @test_throws ArgumentError Grafico.seek!(planned, NaN)
    @test_throws ArgumentError Grafico.seek!(planned, Inf)
    off(listener)

    # A closed path contains information that its identical endpoints cannot encode.
    path = Observable(0.37)
    custom = Grafico.plan(along(path, (start, u) -> start + 0.25sinpi(8u); duration = 4))
    for time in (0.17, 3.131, 0.7, 4.0, 1.11, 0.0)
        Grafico.seek!(custom, time)
        @test path[] ≈ 0.37 + 0.25sinpi(2time)
    end

    # Values are captured when planned, including mutable starts and destinations.
    initial = [1.0, 2.0]
    target = [5.0, 8.0]
    points = Observable(initial)
    description = to(points => target; duration = 2, ease = identity)
    initial[1] = 2.0
    captured = Grafico.plan(description)
    initial[1] = 100.0
    target[1] = 200.0
    Grafico.seek!(captured, 0.5)
    @test points[] == [2.75, 3.5]
    points[][1] = -100.0
    Grafico.seek!(captured, 2)
    @test points[] == [5.0, 8.0]
    Grafico.seek!(captured, 0)
    @test points[] == [2.0, 2.0]
end

@testset "Motion composition" begin
    x, y = Observable(0.0), Observable(10.0)
    description = together(
        to(x => 8.0; duration = 4, ease = identity),
        sequence(hold(1), to(y => -2.0; duration = 2, ease = identity)),
    )
    planned = Grafico.plan(retime(description; duration = 8))
    Grafico.seek!(planned, 3.0)
    @test (x[], y[]) == (3.0, 7.0)
    Grafico.seek!(planned, 7.0)
    @test (x[], y[]) == (7.0, -2.0)

    sources = [Observable(0.0) for _ in 1:3]
    cascade = Grafico.plan(stagger([to(s => 1.0; duration = 2, ease = identity) for s in sources]; gap = 0.5))
    @test Grafico.duration(cascade) == 3.0
    Grafico.seek!(cascade, 0.75)
    @test getindex.(sources) == [0.375, 0.125, 0.0]
    Grafico.seek!(cascade, 2.75)
    @test getindex.(sources) == [1.0, 1.0, 0.875]
    @test Grafico.duration(sequence()) == 0
    @test Grafico.duration(together()) == 0
    @test Grafico.duration(stagger()) == 0
    @test Grafico.seek!(Grafico.plan(hold(2)), 0.7).time[] == 0.7

    @test_throws ArgumentError hold(-1)
    @test_throws ArgumentError to(x => 1; duration = Inf)
    @test_throws ArgumentError stagger(hold(1); gap = -1)
    @test_throws ArgumentError retime(hold(0); duration = 1)
    @test_throws ArgumentError retime(hold(1); duration = 0)
end

@testset "Conflicting writes are rejected before publication" begin
    value = Observable(0.0)
    @test_throws ArgumentError to(value => 1, value => 2)
    @test_throws ArgumentError to(1 => 2)
    @test_throws ArgumentError to()
    for (a, b) in ((2, 3), (3, 2), (0, 2), (2, 0), (0, 0))
        @test_throws ArgumentError Grafico.plan(together(
            to(value => 1; duration = a), to(value => 2; duration = b)))
    end
    @test_throws ArgumentError Grafico.plan(stagger(
        to(value => 1; duration = 2), to(value => 2; duration = 2); gap = 1))
    @test value[] == 0

    serial = Grafico.plan(sequence(
        to(value => 1; duration = 0), to(value => 2; duration = 0),
        to(value => 4; duration = 2, ease = identity),
        to(value => 10; duration = 0),
        to(value => 14; duration = 2, ease = identity)))
    Grafico.seek!(serial, 0)
    @test value[] == 2
    Grafico.seek!(serial, 1)
    @test value[] == 3
    Grafico.seek!(serial, 2)
    @test value[] == 10
    Grafico.seek!(serial, 3)
    @test value[] == 12
    Grafico.seek!(serial, 0)
    @test value[] == 2
end

@testset "Native Makie values" begin
    values = [
        (Observable(0), 10, 5),
        (Observable(false), true, false),
        (Observable(:a), :b, :a),
        (Observable((0.0, 2.0)), (4.0, 8.0), (2.0, 5.0)),
        (Observable((x = 0.0, y = 2.0)), (x = 4.0, y = 8.0), (x = 2.0, y = 5.0)),
        (Observable(zeros(2, 2)), ones(2, 2), fill(0.5, 2, 2)),
        (Observable(Point2f[(0, 0), (1, 1)]), Point2f[(2, 4), (3, 5)], Point2f[(1, 2), (2, 3)]),
        (Observable(RGBAf(1, 0, 0, 1)), RGBAf(0, 0, 1, 0), RGBAf(0.5, 0, 0.5, 0.5)),
        (Observable(Rect2f(0, 0, 2, 2)), Rect2f(2, 4, 6, 8), Rect2f(1, 2, 4, 5)),
    ]
    for (observable, target, middle) in values
        planned = Grafico.plan(to(observable => target; duration = 2, ease = identity))
        Grafico.seek!(planned, 1)
        @test observable[] == middle
        Grafico.seek!(planned, 2)
        @test observable[] == target
    end
    ragged = Observable([1.0, 2.0])
    planned = Grafico.plan(to(ragged => [3.0]; duration = 2))
    Grafico.seek!(planned, 1)
    @test ragged[] == [1.0, 2.0]
    Grafico.seek!(planned, 2)
    @test ragged[] == [3.0]
end

@testset "The same motion drives ordinary Grafico Observables" begin
    angle, stretch = Observable(0.0), Observable(1.0)
    source = Point2d[(1, 0), (0, 1), (-1, 0)]
    rows = lift(angle, stretch) do a, s
        (; x = [cos(a) * s * p[1] - sin(a) * p[2] for p in source],
           y = [sin(a) * s * p[1] + cos(a) * p[2] for p in source])
    end
    alpha = Observable(1.0)
    window = Observable((-2.0, 2.0))
    calls = Ref(0)
    counted = transformation(p -> (calls[] += 1; p))
    graph = data(rows) * mapping(:x, :y) * counted * visual(Scatter; alpha, color = Cycled(1)) +
            coord(x = (limits = window,), y = (limits = (-2., 2.),))
    fig = figure(graph)
    axis, points = only(axes_of(fig)), only(plots_of(fig, Scatter))
    planned = Grafico.plan(sequence(
        together(to(angle => π / 2, stretch => 1.5; duration = 2, ease = identity)),
        to(alpha => 0.25, window => (-1.0, 1.0); duration = 1, ease = identity)))
    Grafico.seek!(planned, 2)
    @test points[1][] ≈ Point2d[(0, 1.5), (-1, 0), (0, -1.5)] atol = 1e-12
    before = calls[]
    Grafico.seek!(planned, 2.5)
    @test points.alpha[] == 0.625
    @test axis.limits[][1] == (-1.5, 1.5)
    @test calls[] == before
    @test only(axes_of(fig)) === axis
    @test only(plots_of(fig, Scatter)) === points
    @test size(colorbuffer(fig), 1) > 0
    Grafico.seek!(planned, 0)
    @test points[1][] ≈ source
end
