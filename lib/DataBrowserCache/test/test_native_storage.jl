using Test, DataBrowserCache

@testset "native memory storage" begin
    store = MemoryStore(; max_bytes=20_000)
    write(store, "one", zeros(1000))
    write(store, "two", ones(1000))
    @test read(store, Vector{Float64}, "one") == zeros(1000)
    write(store, "three", fill(3.0, 1000))
    @test !haskey(store, "one")
    @test haskey(store, "two")
    @test haskey(store, "three")
    @test_throws KeyError read(store, Vector{Float64}, "one")
    @test_throws ArgumentError read(store, String, "two")
    write(store, "oversized", zeros(10_000))
    @test haskey(store, "oversized")
    write(store, "nothing", nothing)
    @test haskey(store, "nothing")
    @test read(store, Nothing, "nothing") === nothing
    @test !haskey(store, "oversized")
    delete!(store, "nothing")
    @test !haskey(store, "nothing")
    @test_throws ArgumentError MemoryStore(; max_bytes=-1)
end
