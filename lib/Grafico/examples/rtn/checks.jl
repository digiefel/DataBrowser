module GraficoRtnIntegrationChecks

using Test
include("rtn.jl")

function native_plots(axis, kind)
    found = Any[]
    function visit(plot)
        plot isa kind && push!(found, plot)
        foreach(visit, plot.plots)
    end
    foreach(visit, axis.scene.plots)
    found
end

@testset "Grafico RTN panels and Observable animation" begin
    original = copy(trace.raw)
    Grafico.seek!(playback, 0)
    @test count(block -> block isa Axis, fig.content) == 1
    @test samples_shown[] == 1
    @test subtraction[] == 0
    @test model_opacity[] == 0
    @test residual[] == trace.raw
    start = copy(colorbuffer(fig))

    Grafico.seek!(playback, Grafico.duration(playback))
    @test count(block -> block isa Axis, fig.content) == 5
    @test samples_shown[] == length(trace.t)
    @test residual[] ≈ trace.corrected
    @test length(samples[].current) == length(trace.t)
    final = copy(colorbuffer(fig))
    @test start != final

    Grafico.seek!(playback, 2)
    @test time_window[][2] - time_window[][1] < last(trace.t) - first(trace.t)
    Grafico.seek!(playback, 0)
    @test colorbuffer(fig) == start
    Grafico.seek!(playback, Grafico.duration(playback))
    @test colorbuffer(fig) == final

    lag[] = 7
    lag_axes = filter(block -> block isa Axis && block.xlabel[] == "I(t) / µA", fig.content)
    raw_lag_axis = argmax(axis -> Makie.viewport(axis.scene)[].origin[2], lag_axes)
    dots = only(native_plots(raw_lag_axis, Scatter))
    @test length(dots[1][]) == length(trace.t) - 7
    @test first(dots[1][]) ≈ Point2d(trace.raw[1], trace.raw[8])
    @test trace.raw == original
end

end
