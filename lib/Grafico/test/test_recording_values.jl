module NativeRecordingValueChecks
using Test, CairoMakie
include("../ext/recording/values.jl")
@testset "Sparse native updates retain distinct immutable buffers" begin
    pool = ValuePool()
    source = zeros(Float32, 20_000)
    for i in 1:200
        source[503] = i
        entry = Dict(:position => copy(source), :color => Float32[1, 0, 0, 1])
        index = retain!(pool, entry)
        @test pool.values[index][:position][503] == i
        @test retain!(pool, deepcopy(entry)) == index
    end
    @test length(pool.values) == 200
    @test maximum(length, values(pool.indices)) <= 2
    first = pool.values[1]
    @test first[:position][503] == 1
    @test retain!(pool, Dict(:color => copy(first[:color]), :position => copy(first[:position]))) == 1
end
end
