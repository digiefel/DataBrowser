# Can a PackageCompiler app be the runtime?

Question: can an app built with PackageCompiler's `create_app` compile new code at run time and load
packages it was not built with, as the runtime must for a project's code? Checked on 30 October 2026
with Julia 1.13.3 on macOS (Apple silicon).

`TinyRuntime` stands in for the runtime: it runs a script given on the command line.
`project_script.jl` stands in for a project's code. Build with `build.jl`, then run:

    TinyRuntimeApp/bin/TinyRuntime project_script.jl

## Results

| Check | Result |
| --- | --- |
| 1. New type, new method, `eval` at run time | works as built |
| 2. A package from a local folder, through `LOAD_PATH` | works as built |
| 3. `Pkg.add("JSON")` from the network, then `using JSON` | works after three fixes below |

The app is 339 MB as built (112 MB of it libraries such as OpenBLAS), 364 MB with the fixes. A run
of all three checks takes 15 s, most of it installing and compiling JSON.

## Fixes needed for `Pkg` inside the app

- **`zstd` is missing.** PackageCompiler copies only `7z` into `libexec/julia`; `Pkg` in Julia 1.13
  needs `zstd` to read the registry. Fixed by copying `zstd` and `zstdmt` from the Julia installation.
- **The standard library sources are missing.** `Pkg` reads `share/julia/stdlib/v1.13` to resolve
  versions. Fixed by copying that folder (14 MB) from the Julia installation.
- **The app's `LOAD_PATH` leaves out the active project.** It holds only the app's own folder, so
  installed packages are not found. Fixed with `pushfirst!(LOAD_PATH, "@")` in the script.

The first two would belong in the runtime's build script; the third in the runtime's startup.
Installed packages go to the app's own depot (`share/julia`), so the app's folder must be writable
or the runtime must set its own depot elsewhere.
