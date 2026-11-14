function evaluate_portable(graph, replacements = IdDict())
    values = Any[]
    for node in graph.nodes
        value = if node.function_value === nothing
            get(replacements, node.observable, node.initial)
        else
            arguments = map(node.arguments) do argument
                argument isa Grafico._ObservableReference ? values[argument.index] : argument
            end
            Base.invokelatest(node.function_value, arguments...)
        end
        push!(values, value)
    end
    values
end

function retained_inputs(grid)
    outputs = Makie.Observable[]
    for (_, child) in grid.content
        if child isa Makie.GridLayoutSpec
            append!(outputs, retained_inputs(child))
        else
            for plot in child.plots
                arguments = if plot.type === :LiveEntry
                    entry = only(plot.args)
                    (entry.positional..., entry.named...)
                else
                    (plot.args..., values(plot.kwargs)...)
                end
                append!(outputs, filter(value -> value isa Makie.Observable, collect(arguments)))
            end
        end
    end
    outputs
end

@testset "Reactive calls retain explicit operands" begin
    x, y = Observable(1.0), Observable(2.0)
    value = Grafico._lift_call((a, b; offset) -> a + b + offset, x, y; offset = x)
    graph = Grafico._observable_graph([value])
    values = evaluate_portable(graph, IdDict(x => 3.0, y => 7.0))
    @test values[only(graph.outputs)] == 13.0
    @test value[] == 4.0
    x[] = 4.0
    @test value[] == 10.0
    @test count(node -> node.function_value === nothing, graph.nodes) == 2
end

@testset "Ordinary Grafico mappings retain numeric data" begin
    rows = Observable((x = [0., 1., 2.], y = [2., 1., 3.]))
    header = data(rows) * mapping(:x, :y => x -> 2x)
    for kind in (Lines, Scatter, BarPlot)
        declaration = header * visual(kind)
        specification = spec(Grafico._retained_plot(declaration))
        sources = retained_inputs(specification)
        @test !isempty(sources)
        graph = Grafico._observable_graph(sources)
        changed = (x = [0., 1., 2., 3.], y = [3., 2., 5., 1.])
        values = evaluate_portable(graph, IdDict(rows => changed))
        outputs = values[graph.outputs]
        @test any(value -> value == changed.x, outputs)
        @test any(value -> value == 2changed.y, outputs)
    end
    column = Observable([1., 3., 2.])
    specification = spec(Grafico._retained_plot(
        data((x = [1., 2., 3.], y = column)) * mapping(:x, :y) * visual(Lines)))
    graph = Grafico._observable_graph(retained_inputs(specification))
    values = evaluate_portable(graph, IdDict(column => [4., 5., 6.]))
    @test any(value -> value == [4., 5., 6.], values[graph.outputs])
end

@testset "Makie compute edges and Observable adapters share dependencies" begin
    pipeline = Makie.ComputePipeline
    source = Observable([1., 2., 3.])
    graph = Grafico._observable_graph([source])
    native = pipeline.ComputeGraph()
    pipeline.add_input!(native, :data, source)
    pipeline.add_input!(native, :scale, 2.0)
    map!(native, [:data, :scale], [:scaled, :kind]) do data, scale
        (scale .* data, :numeric)
    end
    mapped = lift(values -> values .+ 1,
        pipeline.get_observable!(native, :scaled; use_deepcopy = false))
    child = pipeline.ComputeGraph()
    pipeline.add_input!(child, :positions, mapped)
    map!(sum, child, :positions, :total)
    roots = [child[:total], native[:kind]]
    captured, outputs = Grafico._append_compute_graph(graph, roots, [native, child])
    @test outputs[1] isa Grafico._ObservableReference
    @test outputs[2] === nothing
    for values in (Float64[], [2., 7.], collect(1.:9.))
        evaluated = evaluate_portable(captured, IdDict(source => values))
        @test evaluated[outputs[1].index] ≈ sum(2 .* values .+ 1)
    end
end

@testset "Native cached state cannot silently become a pure computation" begin
    pipeline = Makie.ComputePipeline
    source = Observable(1.0)
    graph = Grafico._observable_graph([source])
    native = pipeline.ComputeGraph()
    pipeline.add_input!(native, :input, source)
    Makie.register_computation!(native, [:input], [:state]) do (input,), changed, cached
        (cached === nothing ? input : cached.state + 1,)
    end
    @test native[:state][] == 1
    source[] = 10
    @test native[:state][] == 2
    @test_throws ArgumentError Grafico._append_compute_graph(graph, [native[:state]], [native])
end

@testset "Analyses retain data, weights, and global bounds" begin
    rows = Observable((current = [0.1, 0.2, 0.5, 0.8], weight = [1., 2., 1., 3.]))
    for options in ((bins = range(0, 1; length = 6),), (bins = 5,))
        declaration = data(rows) * mapping(:current; weights = :weight) *
            Grafico.histogram(; options...)
        sources = retained_inputs(spec(Grafico._retained_plot(declaration)))
        @test !isempty(sources)
        graph = Grafico._observable_graph(sources)
        for changed in (
            (current = [0.1, 0.3, 0.9], weight = [2., 1., 3.]),
            (current = [2., 3., 4., 5.], weight = [1., 4., 2., 1.]),
        )
            actual = evaluate_portable(graph, IdDict(rows => changed))[graph.outputs]
            reference = spec(data(changed) * mapping(:current; weights = :weight) *
                Grafico.histogram(; options...))
            expected = only(last(only(reference.content)).plots).args
            @test any(value -> value == expected[1], actual)
            @test any(value -> value == expected[2], actual)
        end
        initial = copy(first(sources)[])
        rows[] = (current = [0.1, 0.9], weight = [2., 1.])
        @test first(sources)[] == initial
    end
end

@testset "Automatic bar widths survive singleton input" begin
    source = Observable([1.0])
    width = Grafico._data_width(Grafico._RetainedArray(source))
    graph = Grafico._observable_graph([width])
    @test eltype(width) === Float64
    actual = evaluate_portable(graph, IdDict(source => [1.0, 1.3]))
    @test actual[only(graph.outputs)] ≈ 0.3
end

@testset "Scoped native lifts retain their numeric producer" begin
    source = Observable([1., 2., 3.])
    graph = Grafico._observable_graph([source])
    scope = Makie.Scene()
    mapped = Makie.lift(values -> values .* 3, scope, source)
    native = Makie.ComputePipeline.ComputeGraph()
    Makie.ComputePipeline.add_input!(native, :data, mapped)
    map!(sum, native, :data, :total)
    captured, outputs = Grafico._append_compute_graph(graph, [native[:total]], [native];
        callbacks = scope.deregister_callbacks)
    @test outputs[1] isa Grafico._ObservableReference
    for values in (Float64[], [2., 7.], collect(1.:9.))
        evaluated = evaluate_portable(captured, IdDict(source => values))
        @test evaluated[outputs[1].index] == 3sum(values)
    end
end
