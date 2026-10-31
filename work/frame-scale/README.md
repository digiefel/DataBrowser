# GUI work per frame at 10k, 100k and 1M items

`frame_cost.jl` times what the item panel and one window do at each frame, before and after the
change that keeps their results until an input changes. "Before" forces the work the old code did
at every frame. Measured on 31 October 2026, Apple silicon, Julia 1.13.3, `--threads=auto`.

Milliseconds per frame (median of 11):

| items | item filter on, before | after | window on fixed items, before | after | window on the selection, before | after |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10,000 | 3.2 | 0.0002 | 1.6 | 0.0002 | 0.57 | 0.023 |
| 100,000 | 31 | 0.0002 | 23 | 0.0002 | 5.6 | 0.29 |
| 1,000,000 | 326 | 0.0002 | 241 | 0.0002 | 52 | 1.1 |

A window on the selection still costs time in proportion to the selection: the selection is hashed
at each frame (`TODO(scale)` in `Browser/Tags.jl`). At 1M items that is 1.1 ms per frame and window.

Opening the benchmark workspace took 34 s for 100k items and 466 s for 1M items.
