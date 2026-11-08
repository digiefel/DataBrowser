module PayloadConversionProbe
import AlgebraOfGraphics as AoG
import Makie

struct TracePayload
    x::Vector{Float64}
    y::Vector{Float64}
end
Makie.convert_arguments(::Type{<:Makie.Lines}, p::TracePayload) = Makie.convert_arguments(Makie.Lines, p.x, p.y)

function attempt(f, label)
    try
        f()
        println(label, ": PASS")
        return true
    catch error
        message = sprint(showerror, error)
        println(label, ": ", first(split(message, '\n')))
        return false
    end
end
function run()
    z = [sin(x) * cos(y) for x in 1:5, y in 1:4]
    trace = TracePayload([1.,2.,3.], [2.,1.,4.])
    attempt("native Makie heatmap matrix") do
        Makie.heatmap(z)
    end
    attempt("native Makie custom Lines conversion") do
        Makie.lines(trace)
    end
    attempt("AoG data(matrix)") do
        AoG.draw(AoG.data(z) * AoG.visual(Makie.Heatmap))
    end
    attempt("AoG data(custom payload)") do
        AoG.draw(AoG.data(trace) * AoG.visual(Makie.Lines))
    end
    for (label, type, payload) in (("matrix", Makie.Heatmap, z), ("custom trace", Makie.Lines, trace))
        args = Makie.convert_arguments(type, payload)
        println(label, " converted argument types: ", typeof.(args))
        attempt("AoG from converted $label arguments") do
            AoG.draw(AoG.pregrouped(([arg] for arg in args)...) * AoG.visual(type))
        end
    end
    attempt("AoG semantic matrix adapter") do
        AoG.draw(AoG.pregrouped([axes(z,1)], [axes(z,2)], [z]) * AoG.visual(Makie.Heatmap))
    end
    attempt("AoG semantic trace adapter") do
        AoG.draw(AoG.pregrouped([trace.x], [trace.y]) * AoG.visual(Makie.Lines))
    end
    println("Julia ", VERSION, "; AoG ", pkgversion(AoG), "; Makie ", pkgversion(Makie))
    nothing
end
end
