# Over-invalidation in a type-API project with two item types. Run from the repo root:
#   julia --startup-file=no --project=bench research_notes/code-change-detection/R-review/r03_type_api_overinclusion.jl
# Roots are resolved on the concrete item type (design.md, integration review).
# For each one-line edit, the table lists the stages whose revision changes ("rerun"), with the
# prototype rule and with the design's type rule. Ideally only the edited item type's stage reruns.
using DataBrowser
import DataBrowser: process, analyze, label, id
include(joinpath(@__DIR__, "harness.jl"))

Core.eval(Main, quote
    struct LabProject <: DataBrowser.AbstractProject end
    struct IVCurve <: DataBrowser.AbstractDataItem; v::Vector{Float64}; i::Vector{Float64}; end
    struct RTCurve <: DataBrowser.AbstractDataItem; t::Vector{Float64}; r::Vector{Float64}; end
    id(c::IVCurve) = "iv"; id(c::RTCurve) = "rt"
    label(c::IVCurve) = "I-V"
    label(c::RTCurve) = "R-T"
    resistance(c::IVCurve) = sum(c.v) / sum(c.i)
    process(c::IVCurve) = IVCurve(c.v, c.i .* 1e3)
    process(c::RTCurve) = RTCurve(c.t, c.r ./ resistance(IVCurve([1.0], [1.0])))
    analyze(c::IVCurve) = Dict(:R => resistance(c))
    analyze(c::RTCurve) = Dict(:Rmax => maximum(c.r))
    # A plot method for the GUI: not a pipeline stage.
    draw_iv(ax, c::IVCurve) = (ax, c.v, c.i)
end)

const STAGES = [
    "IV process" => () -> [which(process, (IVCurve,))],
    "IV analyze" => () -> [which(analyze, (IVCurve,))],
    "RT process" => () -> [which(process, (RTCurve,))],
    "RT analyze" => () -> [which(analyze, (RTCurve,))],
]
const EDITS = [
    "label(::IVCurve)" => :(label(c::IVCurve) = "IV sweep"),
    "draw_iv (plot only)" => :(draw_iv(ax, c::IVCurve) = (ax, c.i, c.v)),
    "analyze(::RTCurve)" => :(analyze(c::RTCurve) = Dict(:Rmax => maximum(c.r), :Rmin => minimum(c.r))),
    "process(::IVCurve)" => :(process(c::IVCurve) = IVCurve(c.v, c.i .* 1e6)),
]

hashes(rule) = [rule === :prototype ?
    CodeRevision.code_revision(r(); exclude=EXCL).hash :
    CodeRevisionFixed.code_revision(r(); exclude=EXCL, type_rule=rule).hash for (_, r) in STAGES]

const RULE = isempty(ARGS) ? :exact : Symbol(ARGS[1])   # pass `library` for the narrowed rule
println(rpad("edit", 22), " | stages rerun, prototype | stages rerun, type rule :$RULE")
for (name, edit) in EDITS
    h0p = Base.invokelatest(hashes, :prototype); h0f = Base.invokelatest(hashes, RULE)
    Core.eval(Main, edit)
    h1p = Base.invokelatest(hashes, :prototype); h1f = Base.invokelatest(hashes, RULE)
    rerun(a, b) = join([first(STAGES[k]) for k in eachindex(a) if a[k] != b[k]], ", ")
    println(rpad(name, 22), " | ", rpad(rerun(h0p, h1p), 24), " | ", rerun(h0f, h1f))
end
r = CodeRevisionFixed.code_revision(STAGES[1][2](); exclude=EXCL, type_rule=RULE)
println("\nIV process, design rule, methods entered: ", join(sort(unique(string.(r.roots_seen))), "\n  "))
