# Shared demo harness for the review scripts. Each demo runs a stage, applies one change, runs it
# again, and reports what the prototype (A-static-walk/CodeRevision.jl) and the review copy with
# the design.md fixes (CodeRevisionFixed.jl) would do:
#   detected  = output changed, and the hash or the polled hash changed when the check would run
#   MISSED    = output changed, nothing would trigger a rerun (silent stale result)
#   OVER      = output same, but the stage would rerun
# A check runs after a world-counter change (hash) or on every tick (polled hash, fixed copy only).
include(joinpath(@__DIR__, "..", "A-static-walk", "CodeRevision.jl"))
include(joinpath(@__DIR__, "CodeRevisionFixed.jl"))
using .CodeRevision, .CodeRevisionFixed

const EXCL = CodeRevision.LIBRARY_MODULES

function snapshot(roots, rule)
    a = CodeRevision.code_revision(roots; exclude=EXCL)
    b = CodeRevisionFixed.code_revision(roots; exclude=EXCL, type_rule=rule)
    return (world=Base.get_world_counter(), a=a.hash, b=b.hash, poll=poll_hash(b))
end

verdict(changed, s0, s1, prototype) = begin
    world = s0.world != s1.world
    triggered = prototype ? (world && s0.a != s1.a) : ((world && s0.b != s1.b) || s0.poll != s1.poll)
    changed ? (triggered ? "detected" : "MISSED") : (triggered ? "OVER" : "ok")
end

"""
    demo(name, run, roots, change; rule=:exact)

`run()` computes the stage output; `roots()` returns the stage roots; `change` is evaluated in Main.
"""
function demo(name, run, roots, change; rule=:exact)
    out0 = Base.invokelatest(run); s0 = Base.invokelatest(() -> snapshot(roots(), rule))
    Core.eval(Main, change)
    out1 = Base.invokelatest(run); s1 = Base.invokelatest(() -> snapshot(roots(), rule))
    changed = out0 != out1
    println(rpad(name, 58), "output ", changed ? "changed" : "same   ",
        "  prototype: ", rpad(verdict(changed, s0, s1, true), 9),
        "  with fixes ($rule): ", verdict(changed, s0, s1, false))
end
