module TemporalGrammarProbe20261112

using CairoMakie, Grafico, Random, Statistics
import WGLMakie

include("model.jl")
include("checks.jl")
include("projection.jl")

# Recording changes the active backend briefly; the existing WGL app is untouched.
CairoMakie.activate!()
try
    include("scene.jl")
    @testset "Initial frame matches seeking back to zero" begin
        @test length(positions[]) == length(rows)
        initial_positions = copy(positions[])
        Grafico.seek!(playback, 0.6 * Grafico.duration(playback))
        Grafico.seek!(playback, 0 * Grafico.duration(playback))
        @test positions[] == initial_positions
        @test isempty(arrived_data[].current)
    end
    include("render.jl")
finally
    WGLMakie.activate!()
end

end
