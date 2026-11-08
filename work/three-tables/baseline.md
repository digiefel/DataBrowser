# Baseline of the three-tables experiment

Code: branch `three-tables`, commit c0221ac (today's `visualizers` with its uncommitted work).

## Lines

| package | lines | not blank or comment |
|---|---|---|
| DataBrowserCore/src | 5291 | 3974 |
| DataBrowserGUI/src | 7037 | 5954 |

Sections in Core that hold the catalog lock: 83.

## Memory, 100 000 one-row items (work/item-table/memory.jl)

| metadata keys per item | item table | workspace metadata columns | catalog | all live memory |
|---|---|---|---|---|
| 1 | 64.0 MiB | 4.4 MiB | 455.2 MiB | 800.1 MiB |
| 20 | 186.2 MiB | 122.6 MiB | 823.5 MiB | 1449.5 MiB |

Speed (`bench engine`, work/cache-read/throughput.jl, work/scale/scale.jl) is measured back to back
with the experiment at comparison time, on an idle machine.
