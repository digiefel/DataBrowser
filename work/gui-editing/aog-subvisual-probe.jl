module EditorAoGSubvisualProbe
import AlgebraOfGraphics as AoG
import Makie

function run()
    table = (; x=collect(1.0:6.0), y=[3.1, 4.8, 7.2, 8.9, 11.1, 12.9])
    base = AoG.data(table) * AoG.mapping(:x, :y)
    for interval in (:confidence, nothing)
        spec = base * AoG.linear(; interval) *
            AoG.subvisual(:prediction; linewidth=3) *
            AoG.subvisual(:ci; alpha=0.2)
        AoG.draw(spec)
        println("targeted fit draw succeeded: interval=", interval)
    end
    try
        AoG.draw(base * AoG.linear() * AoG.visual(; linewidth=3))
        println("untargeted linewidth unexpectedly accepted")
    catch error
        println("untargeted linewidth rejected: ", first(sprint(showerror, error), 160))
    end
    println("versions: Julia ", VERSION, ", AoG ", pkgversion(AoG), ", Makie ", pkgversion(Makie))
end

run()
end
