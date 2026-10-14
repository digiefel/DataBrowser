# Runnable demos of what the static walk misses.
# Run: julia --startup-file=no research_notes/code-change-detection/A-static-walk/misses.jl
#
# Each demo changes what a stage computes and reports:
#   output changed?  hash changed?  world counter moved?
# A miss is "output changed" with "hash changed" = no, or with "world moved" = no (the recheck
# is triggered by the world counter, so nothing would ask for a new hash).

include(joinpath(@__DIR__, "CodeRevision.jl"))
using .CodeRevision

function demo(name, stage, input, change::Expr)
    out0, h0, w0 = Base.invokelatest(stage, input), code_revision([stage]).hash, Base.get_world_counter()
    Core.eval(Main, change)
    out1, h1, w1 = Base.invokelatest(stage, input), code_revision([stage]).hash, Base.get_world_counter()
    missed = out0 != out1 && (h0 == h1 || w0 == w1)
    println(rpad(name, 48), "output ", out0 != out1 ? "changed" : "same   ", "  hash ",
        h0 != h1 ? "changed" : "same   ", "  world ", w0 != w1 ? "moved" : "same ", missed ? "  MISSED" : "")
end

# 1. A function stored in a container and called through it (dispatch through data).
Core.eval(Main, quote
    fit1(x) = 2x
    const FITS = Any[fit1]
    stage1(x) = FITS[1](x)
end)
demo("1 function held in a container", stage1, 1, :(fit1(x) = 3x))

# 2. A non-const global reassigned: the world counter does not move.
Core.eval(Main, quote
    threshold = 0.5
    stage2(x) = x > threshold
end)
demo("2 non-const global reassigned", stage2, 0.7, :(threshold = 0.9))

# 3. A const container mutated: the world counter does not move.
Core.eval(Main, quote
    const SETTINGS = Dict(:gain => 2)
    stage3(x) = x * SETTINGS[:gain]
end)
demo("3 const Dict mutated", stage3, 1, :(SETTINGS[:gain] = 5))

# 4. A user method on a Base function, reached only through Base code (`sum` calls `iterate`).
Core.eval(Main, quote
    struct Samples; v::Vector{Int}; end
    Base.iterate(s::Samples, i=1) = i > length(s.v) ? nothing : (s.v[i], i + 1)
    stage4(s) = sum(s)
end)
demo("4 user method reached only via Base", stage4, Samples([1, 2]),
    :(Base.iterate(s::Samples, i=1) = i > length(s.v) ? nothing : (10s.v[i], i + 1)))

# 5. A function looked up by a computed name.
Core.eval(Main, quote
    fit_linear(x) = x
    stage5(x) = getfield(Main, Symbol("fit_", "linear"))(x)
end)
demo("5 function looked up by computed name", stage5, 2, :(fit_linear(x) = -x))

# 6. A generated function: the walk sees no lowered body for it.
Core.eval(Main, quote
    @generated gen6(x) = :(x + 1)
    stage6(x) = gen6(x)
end)
demo("6 @generated function body", stage6, 1, :(@generated gen6(x) = :(x + 100)))

# 7. A closure capturing a variable that is reassigned later (Core.Box): no world change.
Core.eval(Main, quote
    function make_stage7()
        k = 1
        stage = x -> x * k
        bump = () -> (k += 1)
        return stage, bump
    end
    stage7, bump7 = make_stage7()
end)
demo("7 boxed closure capture reassigned", stage7, 1, :(bump7()))

# 8. Not code in the session: a registry package upgraded between sessions (e.g. CSV.jl) keeps the
#    hash unchanged because frozen modules are never hashed. No runnable demo in one session.
println(rpad("8 frozen package version changes (disk cache)", 48), "not demonstrable in one session")
