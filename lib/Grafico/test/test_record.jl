@testset "Recording restores the author's state after failure" begin
    x, y = Observable(0.0), Observable(3.0)
    planned = Grafico.plan(to(x => 8.0, y => 7.0; duration = 2))
    Grafico.seek!(planned, 0.75)
    original = (x[], y[], planned.time[])
    observed = Tuple[]
    callback = on(x) do value
        push!(observed, (value, y[], planned.time[]))
    end
    @test_throws ErrorException Grafico._with_motion_state(planned) do
        Grafico.seek!(planned, 2)
        error("render failed")
    end
    @test (x[], y[], planned.time[]) == original
    @test last(observed) == original
    off(callback)
end

@testset "Recording samples exact clip boundaries" begin
    value = Observable(0.0)
    planned = Grafico.plan(sequence(hold(0.13), to(value => 1.0; duration = 0.27)))
    times = Grafico._motion_record_times(planned, 10)
    @test first(times) == 0
    @test last(times) == Grafico.duration(planned)
    @test 0.13 in times
    @test issorted(times) && allunique(times)
    @test_throws ArgumentError Grafico._motion_record_times(planned, 0)
    @test_throws ArgumentError Grafico._motion_record_times(planned, Inf)
    @test_throws ArgumentError record(Figure(), "/tmp/invalid.html", planned; still_at = 1)
end
