using Test, DataBrowserPlots
using DataBrowserPlots: PlotCode
using DataBrowserGUI: CodeFile

@testset "the roles and lines of @plot, with their place in the code" begin
    code = CodeFile(; text="""
        resistance(gap; Rc, Rsh) = 2Rc + Rsh * gap
        @plot mapping(:gap, :R; color=:Chip) begin
            mapping(; marker=:Site) * visual(Scatter)
            contacts = mapping(; color=nothing) * fit(resistance, (Rc=1.0, Rsh=1.0))
            @invisible contacts * visual(Lines)
            scales(color=(; palette=[:red, :blue]))
        end
        """)
    plot = tryparse(PlotCode, code)
    text(range) = code.text[range]
    @test [role => text(range) for (role, range) in plot.mapping.roles] == [1 => ":gap", 2 => ":R", :color => ":Chip"]
    @test [text(line.range) for line in plot.lines] == ["mapping(; marker=:Site) * visual(Scatter)",
        "contacts = mapping(; color=nothing) * fit(resistance, (Rc=1.0, Rsh=1.0))", "contacts * visual(Lines)"]
    @test [line.name for line in plot.lines] == [nothing, :contacts, nothing]
    @test [line.invisible === nothing ? nothing : text(line.invisible) for line in plot.lines] == [nothing, nothing, "@invisible "]
    @test [text(last(only(line.mapping.roles))) for line in plot.lines[1:2]] == [":Site", "nothing"]
    @test plot.lines[3].mapping === nothing

    @test tryparse(PlotCode, CodeFile(; text="x = 1")) === nothing
end
