# Target workflows

[Compare repeated measurements](repeated_measurements/README.md) is a design example for the
workspace we are building. It follows one task from processed measurements through per-sample means,
an ordered comparison, reuse and later input changes.

The analysis workflow is shared by GUI, REPL and project users, whether their measurements
were loaded through DBRecipes or a native project. Source loading is outside this example.
The code contains proposed interfaces and explicit unresolved steps. It is not a runnable
example of today's package.

| File | Review purpose |
| --- | --- |
| [Walkthrough](repeated_measurements/README.md) | User actions, expected results, counterexamples and concrete failures in the target proposal |
| [Shared analysis](repeated_measurements/analysis.jl) | Candidate saved calculations, explicit input roles and missing input/result/view operations |
| [Type API](repeated_measurements/type_api.jl) | Proposed groups, native results and the failed attempt to compose produced sample means |
| [Helpers](repeated_measurements/helpers.jl) | Ordinary calculations, independent of workspace machinery |

The acceptance question is whether the proposed API can express and support the complete user
workflow. Compiling a subset against today's API does not answer it. The walkthrough distinguishes
missing design contracts, broken target examples and implementation lag. Canvas editing is deferred.
