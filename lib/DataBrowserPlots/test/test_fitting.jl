using Test, DataBrowserPlots, GLMakie, AlgebraOfGraphics

resistance(gap; Rc, Rsh) = 2Rc + Rsh * gap

@testset "a named fit line fits each group, and other lines draw its results" begin
    # Two chips with exact lines: R = 2 * 300 + 100 * gap and R = 2 * 50 + 100 * gap.
    gaps = [5.0, 10.0, 20.0]
    items = (Chip=["A", "A", "A", "B", "B", "B"], gap=[gaps; gaps],
        data=(R=vcat([[2 * 300 + 100g] for g in gaps], [[2 * 50 + 100g] for g in gaps]),))
    plot = @plot mapping(:gap, only(:data.R); color=:Chip) begin
        visual(Scatter)
        contacts = fit(resistance, (Rc=1.0, Rsh=1.0)) *
            visual(Lines; label="$(contacts.Chip): Rc = $(contacts.Rc)")
        mapping(contacts.x[end], contacts.y[end]) *
            visual(Makie.Text; text="$(contacts.Chip): $(round(contacts.Rc.value)), $(round(contacts.Rsh.value))")
    end
    axis = only(filter(c -> c isa Axis, figure(plot, items).content))
    texts = [only(p.text[]) for p in axis.scene.plots if p isa Makie.Text]
    @test sort(texts) == ["A: 300.0, 100.0", "B: 50.0, 100.0"]
end
