# B. Tracing: which methods did a stage run?

Test stage: `testproject.jl`, a Gauss-Newton curve fit over 1e5 points. It reaches its helpers
through a static call, a dynamic call (`steps[1](...)`), a closure, a keyword call, a Base function
calling back into user code (`sum(closure, ...)`), and a global read (`threshold[]`). Julia 1.13.1.
Each row has a script in this folder.

| Mechanism (script) | Finds the dynamic call? | Base calling back into user code | Run-time cost | First-run cost | Internals used |
|---|---|---|---|---|---|
| Compiler edges after the run (`01`) | **No**: `gn_step`, `jacrow` missing; editing `jacrow` leaves `fit` valid | yes | none | none | `ci.edges`, `Base.specializations` |
| `Base.@trace_dispatch` (`02`) | only the **first** dispatch per process; nothing on run 2 or after a redefinition | – | – | – | global flag, text on stderr, cannot be limited to one task |
| JuliaInterpreter, all interpreted (`03`) | yes, exact | yes | **×200 000** | – | public API of JuliaInterpreter |
| JuliaInterpreter, Base compiled (`03`) | yes | **no** (closure given to `sum` missing) | ×8 000 | – | same |
| Overlay pass, CassetteOverlay (`04`) | **yes**, exact | yes | **×1.03** (fit), ×4.8 (CSV + sort) | 4.9 s (fit); 17 s vs 2.4 s native (CSV + sort) | generated functions returning `CodeInfo`, overlay method tables |
| `code_typed` scan of dynamic sites (`06`) | finds the *site*, not the callee | – | none | inference only | `code_typed` |

## How the overlay pass works

`pass(process, item)` runs `process` with every call `f(args...)` rewritten to `pass(f, args...)`,
at every depth, including calls dispatched at run time. Each new signature (argument types)
compiles once. After the run, the compiled specializations of the pass method are the list of call
signatures the stage reached. Nothing is recorded per call, so the steady-state speed is close to
native. One pass type per stage keeps the lists apart. Unused helpers are not reported.

The list is a safe superset: it includes branches that were compiled but not taken, and it grows as
more items run. Storing *signatures* (not methods) has a useful property: after any edit,
re-resolving each signature with `which` also catches a newly added method that now wins dispatch.

## What tracing misses

| Construct (`05`) | Overlay pass |
|---|---|
| `try ... catch` | recorded |
| `Threads.@spawn`, `invokelatest`, `eval`, `@cfunction` | **not recorded**: the callee runs outside the pass. Fixable one by one with overlay methods, or detectable and refused |
| global data (`threshold[]`, a `Dict` filled at load time) | not seen by any mechanism: a global read is not a call |
| files, environment, random state | not seen |

## Assessment

- Compiler edges and `@trace_dispatch` cannot close the dynamic-dispatch gap.
- JuliaInterpreter is exact but too slow for any real stage; it is only useful as a test oracle.
- One dynamic call makes everything downstream dynamic (the `Any` result of `steps[1](...)` left 5
  dynamic call sites in `fit`), so instrumenting only dynamic sites amounts to instrumenting most of
  the stage, which is what the overlay pass does.
- The overlay pass is the only exact and fast tracer. Its costs: up to ~7× more compile time on the
  first run of a stage (CSV stage), up to ~5× slower run time in dispatch-heavy package code, a
  dependency on compiler internals (CassetteOverlay has needed updates for past Julia releases), and
  the silent escapes above.

**Recommendation.** Do not use tracing as the main mechanism: it only knows the dependencies after
the stage has run, it multiplies first-run compile time, and it still misses global data and the
escapes above without saying so. The overlay pass is a fallback for stages where approach A or C
finds dynamic calls it cannot resolve, with `@spawn`/`invokelatest`/`eval` overlaid or refused.

`05` prints harmless world-age warnings (it defines a pass type at run time). `06` skips closures
when following calls: an illustration, not a complete scan.
