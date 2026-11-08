# Feasibility probe of result-preserving statistics and generic AoG lowering.
# This is not an implementation of @plot, name resolution, or GUI source editing.
module FitResultLoweringProbe
import AlgebraOfGraphics as AoG
import Makie
import GLM
import Tables

function prepare(x, y, categories; calls=Ref(0))
    length(x) == length(y) == length(categories) || error("Unaligned inputs")
    map(unique(categories)) do category
        ids = findall(==(category), categories)
        xg, yg = x[ids], y[ids]
        calls[] += 1
        model = GLM.lm(hcat(ones(length(xg)), xg), yg)
        intercept, slope = GLM.coef(model)
        xp = collect(range(extrema(xg)...; length=31))
        yp = GLM.predict(model, hcat(ones(length(xp)), xp))
        (; model, x=xp, y=yp, slope, intercept, r2=GLM.r2(model),
           group=(; color=category))
    end
end

# Each generated branch uses the same prepared record. There is no Text-specific
# result path: positions and every visual keyword are ordinary evaluated values.
function lower(records; prefix="Gain = ", digits=2)
    layers = AoG.Layer[]
    for record in records
        category = record.group.color
        push!(layers, AoG.pregrouped([record.x], [record.y]; color=[category]) *
            AoG.visual(Makie.Lines; linewidth=1 + abs(record.slope)))
        push!(layers, AoG.pregrouped([[last(record.x)]], [[last(record.y)]]; color=[category]) *
            AoG.visual(Makie.Text; text=prefix * string(round(record.slope; digits)),
                offset=(8, 0), align=(:left, :center)))
        push!(layers, AoG.pregrouped([[0.0]], [[record.intercept]]; color=[category]) *
            AoG.visual(Makie.Scatter; marker=:xcross, markersize=12))
    end
    reduce(+, layers)
end

function run()
    x = repeat(collect(1.0:6.0), 2)
    y = [3.2, 4.7, 7.1, 9.1, 10.7, 13.2, 3.38, 3.16, 2.46, 1.96, 1.66, 0.88]
    categories = repeat(["A", "B"]; inner=6)
    calls = Ref(0)
    records = prepare(x, y, categories; calls)
    @assert calls[] == 2
    @assert isapprox(records[1].slope, 2; atol=1e-12)
    @assert isapprox(records[2].slope, -.5; atol=1e-12)
    retained = [r.model for r in records]
    for digits in (2, 3)
        observed = AoG.mapping(x, y; color=categories) * AoG.visual(Makie.Scatter; markersize=6)
        plotted = AoG.draw(observed + lower(records; digits))
        plots = plotted.grid[1, 1].axis.scene.plots
        texts = filter(p -> p isa Makie.Text, plots)
        lines = filter(p -> p isa Makie.Lines, plots)
        @assert length(texts) == length(lines) == 2
        @assert sort([p.linewidth[] for p in lines]) == [1.5, 3.0]
        @assert sort([only(p.text[]) for p in texts]) == ["Gain = -0.5", "Gain = 2.0"]
        @assert calls[] == 2
        @assert all(records[i].model === retained[i] for i in eachindex(retained))
    end
    table = (; x, y, series=categories)
    columns = Tables.columntable(table)
    from_table = prepare(columns.x, columns.y, columns.series)
    @assert all(isapprox(a.slope, b.slope; atol=1e-12) for (a, b) in zip(records, from_table))
    println("Native GLM models retained: ", typeof(first(records).model))
    println("Vector input: 2 fits reused for lines, coefficient text and intercept markers.")
    println("Computed linewidths: A=3.0, B=1.5. Text precision change: no refit.")
    println("Tables.jl input: same slopes. Public AoG pregrouped/visual/draw only.")
    println("Not covered: macro/source bindings, facets, scales, inferred grouping or arbitrary payload adapters.")
    println("Julia ", VERSION, "; AoG ", pkgversion(AoG), "; Makie ", pkgversion(Makie), "; GLM ", pkgversion(GLM))
    nothing
end
end
