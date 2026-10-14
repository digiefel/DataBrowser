# C: load-time transform — findings

Prototype: `src/CodeTrack.jl` (~690 lines, needs only Base). Julia 1.13.1, Revise 3.17.3. Run the
scripts with `julia --startup-file=no --project=. <script>`. `demo_macros.jl` and
`transform_project.jl` need the user's environment (`--project="<project dir>"`).

## How it works

`TrackCode(mod)` is the transform passed to `include`, `Revise.track` and the REPL's
`ast_transforms`. It wraps each top-level statement in `@track`. When Julia lowers the statement,
`@track` expands its macros and makes these changes:

| Change | Where | What it records |
|---|---|---|
| `enter(self, args...)` | first line of every user method, closure, do-block and keyword-argument function | function type and runtime argument types; a later check dispatches that signature again |
| `gread(mod, :x, x)` | reads of non-const globals, and of const globals that hold mutable values | full content hash of the value, once per run |
| refusal at load | `eval`, `@eval` or `include` inside a function; `@generated`; `module` blocks | — |

**Record at method entry, not at call sites.** Rewriting dynamic call sites (`g[1](x)`, `p.f(x)`,
`cb(x)`) works (`sites=true`), but `enter` catches the same calls and also calls no rewrite can
reach: callbacks run by `map` or by package code, and functions in untyped containers passed to
packages. Because every user method records itself, user code needs no static walk (approach A).
Wrapping a call site in a function (`call(f, x)`) made Julia stop specializing the calling method
on `f`, which was 25× slower; the final version keeps the call direct.

## What it detects (`demo_semantics.jl`, `demo_macros.jl`, `demo_repl.jl`, `demo_struct.jl`)

All 11 patterns, each only when the method it ran or the global it read changed: static call,
`g[1](x)`, `p.f(x)`, callback argument, `map(helper, xs)`, do-block, keyword arguments, broadcast,
non-const global, `@threads`, forward reference. Also a new, more specific method (adding
`helper(::Float64)`), REPL redefinitions, and struct edits saved through Revise.

Macros that run and record: `@kwdef`, `@.`, `@threads`, `@spawn`, `@views`, `@inbounds @simd`,
`@sprintf`, `@info`, `@assert`, `@show`, `@timed`, `@nospecialize`, Makie 0.24 `@recipe` + `plot!`.

## Cost

| Fit over 1e5 points, 5 iterations (`bench_overhead.jl`, 1 thread) | plain | transformed, not recording | recording |
|---|---|---|---|
| 1e6 user-function calls per run (helper per element) | 8.5 ms | 12.9 ms | 20.3 ms |
| helper called by broadcasting (5e5 calls) | 9.3 ms | 11.5 ms | 14.8 ms |
| helper defined after its caller, called per element | 2.6 ms | 5.2 ms | 15.7 ms |

About 8 ns per user-function call while recording, mostly finding the current record. A
`ScopedValue` lookup costs 51 ns and allocates; task-local storage costs 4.5 ns.

| Load and compile | plain | transformed |
|---|---|---|
| User project, 10 files, 1789 lines: macro expansion + transform | — | 130 ms |
| User project: lowered statements | 9084 | 9855 (+8 %) |
| Fit file: first call (compilation), fresh process | 527 ms | 672 ms (+28 %) |

## Revise and stack traces

- On save, Revise applies the transform again (`Revise.track(TrackCode(mod), mod, file)`) and
  redefines only the edited method. `includet(TrackCode(mod), mod, file)` works too.
- Expanding macros inside the transform broke this: `@sprintf` puts an object into the expression
  that never compares equal, so Revise redefined that method on every save. Expansion is therefore
  delayed with `@track`.
- Stack traces show the same user frames and line numbers, no CodeTrack frames. Some frames are no
  longer inlined, so they show argument types.

## Real project (`transform_project.jl`, nothing run)

All 140 statements of the DataBrowser project transform. In the 15 standalone scripts, 5 statements
are refused: 3 `module` blocks and 2 `Base.include(@__MODULE__, path)` calls inside a function.
Insertions: 89 `enter`, 53 `gread`, 243 `gread_maybe`. DataBrowser did not precompile from the
project environment (DataBrowserCore loads DataBrowserAnnotations, which is not in its
dependencies), so an empty stand-in module replaced it.

## What it cannot see

- Code in packages loaded with `using`, including `dev`ed packages edited under Revise.
- I/O: file contents, environment variables, time, unseeded `rand`.
- State held in package globals, for example a Makie theme set with `set_theme!`.
- A new user method on a package function that changes which method runs, where no user method
  ran before (adding `Base.show(::IO, ::MyType)` after a run that used the default).
- Code loaded without the transform. FIXME: to fail loudly, scan the user module for methods that
  have no `enter` call.
- Values nested deeper than 8 levels are hashed by identity (TODO in `content_hash`).
- Not tested yet: a struct used only inside method bodies, not in any signature.

## Recommendation

Use C with method-entry recording as the change detector for user code. Leave out call-site
rewriting. Add a check for user methods added to package functions. Every approach needs a hook on
global reads, and here it costs little.
