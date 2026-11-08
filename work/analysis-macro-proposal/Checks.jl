using Test
using .AnalysisMacroProposal

const counts = Dict(:grid=>0, :gradient=>0, :comparison=>0)
function checked_grid(points; scale=2)
    counts[:grid] += 1
    temporary = points .* scale
    temporary .+ 1
end
function checked_gradient(grid)
    counts[:gradient] += 1
    grid .* 2
end
function checked_comparison(points, grid)
    counts[:comparison] += 1
    grid .- points
end

@testset "Saved analysis and canvas contracts" begin
    @analyze candidate(samples; scale=2) begin
        comparison = checked_comparison(samples, grid) # forward reference
        grid = checked_grid(samples; scale=scale)
        gradient = checked_gradient(grid)
    end
    @analyze alternative(samples) begin
        shifted = samples .+ 100
    end
    @test all(iszero, values(counts))
    @test length(graph(candidate)) == 3 # The helper's temporary is not a graph node.
    input = Input("sample-A", [1,2,3])
    @analyze coarse_check = candidate(input; scale=2)
    @analyze fine_check = candidate(input; scale=4)
    @analyze other_check = alternative(input)
    runtime = Evaluator()
    first_run = evaluate(runtime, coarse_check; targets=[:grid])
    @test data(first_run[:grid]) == [3,5,7]
    @test counts == Dict(:grid=>1, :gradient=>0, :comparison=>0) # Demand, not eager evaluation.
    @test members(first_run[:grid]) == [input] # Parameters are not measurement members.
    @test evaluate(runtime, coarse_check; targets=[:grid])[:grid] === first_run[:grid]
    @test counts[:grid] == 1
    completed = evaluate(runtime, coarse_check)
    @test data(completed[:comparison]) == [2,3,4]
    @test data(completed[:gradient]) == [6,10,14]
    @test counts == Dict(:grid=>1,:gradient=>1,:comparison=>1)
    @test members(completed[:gradient]) == [completed[:grid]]
    @test members(completed[:comparison]) == [input,completed[:grid]]
    finer = evaluate(runtime, fine_check)
    @test data(finer[:grid]) == [5,9,13]
    @test finer[:grid].id != completed[:grid].id
    @test typeof(finer[:grid]) === typeof(completed[:grid])
    @test data(evaluate(runtime, other_check)[:shifted]) == [101,102,103]
    @test data(completed[:grid]) == [3,5,7]

    # Direct helper-code replacement refreshes only that node and its downstream consumers.
    before_edit = copy(counts)
    Core.eval(@__MODULE__, :(function checked_gradient(grid)
        counts[:gradient] += 1
        grid .* 3
    end))
    after_edit = evaluate(runtime, coarse_check)
    @test data(after_edit[:gradient]) == [9,15,21]
    @test after_edit[:grid] === completed[:grid]
    @test after_edit[:comparison] === completed[:comparison]
    @test counts[:gradient] == before_edit[:gradient]+1
    @test counts[:grid] == before_edit[:grid]
    @test counts[:comparison] == before_edit[:comparison]
    @test data(completed[:gradient]) == [6,10,14]

    @canvas check_tab begin
        image = heatmap(coarse_check.grid; colormap=:viridis)
        fine_image = heatmap(fine_check.grid)
        table_view = table(coarse_check.comparison; digits=3)
    end
    views = present(check_tab, runtime)
    before_style = copy(counts)
    @canvas recolored begin
        image = heatmap(coarse_check.grid; colormap=:plasma)
        fine_image = heatmap(fine_check.grid)
        table_view = table(coarse_check.comparison; digits=3)
    end
    changed_views = present(recolored, runtime)
    @test counts == before_style
    @test views[1].output === changed_views[1].output
    @test changed_views[1].settings == (; colormap=:plasma)
    # Defaults must preserve identity across direct requests AND different/renamed canvases.
    direct_grid = evaluate(runtime,coarse_check;targets=[:grid])[:grid]
    before_another_canvas = copy(counts)
    @canvas another_canvas begin
        same_data = heatmap(coarse_check.grid; colormap=:gray)
    end
    another_view = only(present(another_canvas,runtime))
    @test another_view.output === direct_grid
    @test another_view.output.id == direct_grid.id
    @test counts == before_another_canvas
    @canvas renamed_canvas begin
        same_data = heatmap(coarse_check.grid; colormap=:gray)
    end
    @test only(present(renamed_canvas,runtime)).output === direct_grid
    @test counts == before_another_canvas

    # Canvas source generation round-trips the actual instances and settings.
    sandbox = Module(:SavedMacroCheck)
    Core.eval(sandbox, :(const AnalysisMacroProposal = $(parentmodule(AnalysisDefinition))))
    Core.eval(sandbox, :(using .AnalysisMacroProposal))
    Core.eval(sandbox, :(coarse_check = $coarse_check))
    Core.eval(sandbox, :(fine_check = $fine_check))
    Base.include_string(sandbox, emit_canvas(check_tab), "generated-canvas.jl")
    regenerated = present(getfield(sandbox,:check_tab), runtime)
    @test [(v.view,v.kind,v.output.id,v.settings) for v in regenerated] ==
          [(v.view,v.kind,v.output.id,v.settings) for v in views]

    # Saved source reload, independent statement order, changed code, same output identity.
    mktempdir() do directory
        file = joinpath(directory,"analysis.jl")
        write(file,"@analyze saved(x; scale=2) begin\n shifted = x .+ 1\n scaled = x .* scale\nend\n")
        saved_definition = Base.include(sandbox,file)
        saved1 = evaluate(runtime,saved_definition,"kept";x=input)
        Core.eval(sandbox, :(saved_input = $input))
        held_instance = Base.include_string(sandbox, "@analyze held = saved(saved_input)")
        held_before = evaluate(runtime,held_instance)
        write(file,"@analyze saved(x; scale=2) begin\n scaled = x .* scale\n shifted = x .+ 1\nend\n")
        reordered_definition = Base.include(sandbox,file)
        reordered = evaluate(runtime,reordered_definition,"kept";x=input)
        @test reordered[:scaled] === saved1[:scaled]
        @test reordered[:shifted] === saved1[:shifted]
        write(file,"@analyze saved(x; scale=2) begin\n scaled = x .* scale .+ 10\n shifted = x .+ 1\nend\n")
        revised_definition = Base.include(sandbox,file)
        revised = evaluate(runtime,revised_definition,"kept";x=input)
        @test data(revised[:scaled]) == [12,14,16]
        @test revised[:scaled].id == saved1[:scaled].id
        @test revised[:shifted] === saved1[:shifted]
        held_after = evaluate(runtime,held_instance) # Existing instance follows named definition reload.
        @test data(held_after[:scaled]) == [12,14,16]
        @test held_after[:scaled].id == held_before[:scaled].id
        @test held_after[:shifted] === held_before[:shifted]
        @test data(held_before[:scaled]) == [2,4,6]
        write(file,"@analyze saved(x; scale=2) begin\n shifted = x .+ 1\nend\n")
        Base.include(sandbox,file)
        @test_throws ErrorException evaluate(runtime,held_instance;targets=[:scaled])
    end

    # Input versions and explicit followed selection: old completed outputs do not change.
    current = Ref(input)
    @analyze following_check = candidate(Follow(() -> current[]))
    live1 = evaluate(runtime,following_check)
    current[] = Input("sample-B",[10,20])
    live2 = evaluate(runtime,following_check)
    @test data(live1[:grid]) == [3,5,7]
    @test data(live2[:grid]) == [21,41]
    @test data(evaluate(runtime,coarse_check)[:grid]) == [3,5,7]
    @analyze reuse(source) begin
        total = sum(source)
    end
    reused = evaluate(runtime,reuse;source=completed[:grid])
    @test only(members(reused[:total])) === completed[:grid]

    before_rejection = copy(counts)
    @analyze cyclic(samples) begin
        a = checked_grid(b)
        b = checked_grid(a)
    end
    @test_throws ErrorException evaluate(runtime,cyclic;samples=input)
    @test_throws ErrorException evaluate(runtime,candidate;samples=input,typo=1)
    @test_throws ErrorException evaluate(runtime,candidate)
    @test_throws ErrorException evaluate(runtime,candidate;samples=[1,2])
    @test_throws ErrorException getproperty(candidate,:grid) # A template is not an instance.
    @test_throws Exception macroexpand(@__MODULE__, :(@analyze duplicate(x) begin y=x; y=x end))
    @test_throws Exception macroexpand(@__MODULE__, :(@analyze bad(x) begin for i in x; println(i); end end))
    @test counts == before_rejection
end
