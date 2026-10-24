using Test, DataBrowserPlots, GLMakie, AlgebraOfGraphics

# Each section of the figure's legend: its title and its entries' texts.
function sections(drawn)
    legend = only(filter(c -> c isa Legend, drawn.content))
    return [(title, [entry.label[] for entry in entries]) for (title, entries) in legend.entrygroups[]]
end

lines(pairs) = [(V=v, I=v / R, Chip=c, Site=s) for (c, s, R) in pairs for v in (0.0, 1.0)]

@testset "roles share a legend section when one of them determines the others" begin
    paired = lines([("72b", "L", 1.0), ("719a", "R", 3.0)])
    plot = @plot data(paired) * mapping(:V, :I; color=:Chip, linestyle=:Site) begin
        visual(Lines)
    end
    @test sections(figure(plot)) == [("Chip, Site", ["72b, L", "719a, R"])]

    crossed = lines([("72b", "L", 1.0), ("72b", "R", 1.5), ("719a", "L", 2.0), ("719a", "R", 3.0)])
    plot = @plot data(crossed) * mapping(:V, :I; color=:Chip, linestyle=:Site) begin
        visual(Lines)
    end
    @test sections(figure(plot)) == [("Chip", ["72b", "719a"]), ("Site", ["L", "R"])]
end

@testset "legend(merge=...) puts roles in one section, with one entry per drawn combination" begin
    crossed = lines([("72b", "L", 1.0), ("72b", "R", 1.5), ("719a", "L", 2.0), ("719a", "R", 3.0)])
    plot = @plot data(crossed) * mapping(:V, :I; color=:Chip, linestyle=:Site) begin
        visual(Lines)
        legend(merge = true)
    end
    @test sections(figure(plot)) == [("Chip, Site", ["72b, L", "72b, R", "719a, L", "719a, R"])]
    plot = @plot data(crossed) * mapping(:V, :I; color=:Chip, linestyle=:Site) begin
        visual(Lines)
        legend(merge = (:color, :linestyle), color = "$(:Chip) at $(:Site)")
    end
    @test sections(figure(plot; legend=(; position=:bottom)))[1][2][1] == "72b at L"
    paired = lines([("72b", "L", 1.0), ("719a", "R", 3.0)])
    plot = @plot data(paired) * mapping(:V, :I; color=:Chip, linestyle=:Site) begin
        visual(Lines)
        legend(merge = false)
    end
    @test sections(figure(plot)) == [("Chip", ["72b", "719a"]), ("Site", ["L", "R"])]
end

@testset "styles written in the visuals of layers are a manual scale with a legend section" begin
    rows = [(V=v, I=v / R, J=-v / R, Chip=c) for (c, R) in (("72b", 1.0), ("719a", 3.0)) for v in (1.0, 2.0)]
    plot = @plot data(rows) * mapping(:V; color=:Chip) begin
        mapping(; y=:I) * visual(ScatterLines; marker=:utriangle, linestyle=:solid)
        mapping(; y=:J) * visual(ScatterLines; marker=:dtriangle, linestyle=:dash)
        scales(marker=(; categories=[:utriangle => "V > 0", :dtriangle => "V < 0"], label="Bias"),
            linestyle=(; categories=[:solid => "V > 0", :dash => "V < 0"]))
    end
    @test sections(figure(plot)) == [("Chip", ["72b", "719a"]), ("Bias", ["V > 0", "V < 0"])]
end

@testset "a legend text reads a value that no role maps, when the entry determines it" begin
    rows = [(V=v, I=v / R, Chip=c, Wafer=w) for (c, w, R) in (("72b", "W1", 1.0), ("719a", "W2", 3.0)) for v in (0.0, 1.0)]
    plot = @plot data(rows) * mapping(:V, :I; color=:Chip) begin
        visual(Lines)
        legend(color = "$(:Chip) on $(:Wafer)", position = :bottom)
    end
    @test sections(figure(plot)) == [("Chip", ["72b on W1", "719a on W2"])]

    # Both chips are on one wafer, so the wafer's entry has two chips.
    @test_throws "has 2 values of Chip" figure(@plot data([(r..., Wafer="W1") for r in rows]) * mapping(:V, :I; linestyle=:Wafer) begin
        visual(Lines)
        legend(linestyle = "$(:Chip)")
    end)
end
