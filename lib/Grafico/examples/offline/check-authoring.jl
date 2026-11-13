module GraficoPortableAuthoringChecks

using Test, Grafico, Makie, WasmTarget
include("lower-observables.jl")

function prepare(outputs, inputs = IdDict{Any,String}())
    roots = Any[]
    bindings = Dict{String,WasmTarget.RootBindings}()
    lower_observables(outputs, inputs, roots, bindings)
end

@testset "Export follows ordinary map and lift dependencies" begin
    source = Observable([1.0, 2.0, 3.0])
    gain = Observable(2.0)
    scaled = lift((values, gain) -> values .* gain, source, gain)
    total = lift(sum, scaled)
    mean = lift((sum, values) -> sum / length(values), total, scaled)
    # Both branches use the same derived vector.
    description = prepare((; scaled, total, mean), IdDict(source => "source", gain => "gain"))
    @test Set(node.name for node in description.nodes if node.function_name === nothing) == Set(["source", "gain"])
    @test length(description.nodes) == 5
    @test source[] == [1.0, 2.0, 3.0]
    @test gain[] == 2.0
    @test total[] == 12.0
    @test mean[] == 4.0
end

@testset "Unsupported dependency contracts fail during export" begin
    source = Observable(1.0)
    result = Observable(0.0)
    map!(identity, result, source)
    map!(x -> 2x, result, source)
    @test_throws ArgumentError prepare((; result), IdDict(source => "source"))

    a = Observable(1.0)
    b = lift(identity, a)
    map!(identity, a, b; update = false)
    @test_throws ArgumentError prepare((; b))

    visible = Observable(1.0)
    hidden = Observable(2.0)
    captured = let hidden = hidden
        lift(x -> x + hidden[], visible)
    end
    @test_throws ArgumentError prepare((; captured), IdDict(visible => "visible"))

    input = Observable(1.0)
    output = Observable(0.0)
    observer = on(input) do x
        output[] = 2x
    end
    @test_throws ArgumentError prepare((; output), IdDict(input => "input", output => "output"))
    off(observer)

    abstract_input = Observable{Real}(1.0)
    @test_throws ArgumentError prepare((value = abstract_input,), IdDict(abstract_input => "input"))

    left, right = Observable(1.0), Observable(2.0)
    combined = lift(+, left, right)
    @test_throws ArgumentError prepare((; combined), IdDict(left => "same", right => "same"))
    @test_throws ArgumentError prepare((; combined), IdDict(combined => "derived"))
    unrelated = Observable(3.0)
    @test_throws ArgumentError prepare((; combined), IdDict(unrelated => "unused"))
end

end
