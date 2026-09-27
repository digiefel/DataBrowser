# Node states

This document defines the state of one pipeline stage on one catalog row. Job
queues and payload storage use this state; they do not replace it.

## Separate state

One enum cannot describe every relevant fact. Keep these parts separate:

- **Applicability:** whether the project has this stage for this row. A stage is
  absent when dispatch reaches the package's default method; Recipes answers
  from a registration whose callback is `nothing`.
- **Validity:** missing, stale, or fresh for one input revision.
- **Activity:** idle, queued, or running.
- **Failure:** the latest failure for the current revision, if any.
- **Output availability:** whether the output is present. Where it lives is
  fixed by the stage (below), so one bit is enough.
- **Revision:** the input revision a job read and an output represents.

`fresh` means the required output exists and matches the current input
revision. It does not mean that a job is running or that every requester can
materialize the output in the form it needs.

## Required rules

- Invalidation increments the revision, marks the stage stale, and propagates
  downstream. It does not queue work by itself.
- A job captures its input revision. Completion publishes only if that revision
  is still current; otherwise the result is discarded.
- A failure belongs to one revision. It settles current request handles and
  blocks dependent work until retry or invalidation. Persist the failure and its
  revision. Reopening reuses it when inputs match; reopening alone is not a retry.
  Changed inputs invalidate successful and failed outcomes by the same rule.
- A persisted `fresh` stage is restored as fresh only when all required output
  is present and its revision matches the saved completion and current inputs.
  Output references must identify the revision they represent; presence at the
  same node and stage is insufficient after an interrupted buffered write.
  Missing or mismatched output downgrades the stage before pull schedules work.
- Evicting output clears availability and leaves validity unchanged. A consumer
  that needs evicted output reruns the stage that produces it.
- Retry clears the current failure and queues the same revision. Invalidation
  clears failures from older revisions.

## Storage

Validity, activity, the failure flag, output availability and revision are
packed into one 64-bit word per row and stage, stored in `AtomicMemory`. A
reader loads the word once and gets a consistent snapshot without a lock. A
writer updates it with compare-and-swap, which fails if the word changed since
the writer read it. Failure messages are text and rare; they live in a separate
table under an ordinary lock.

## Output location

| Stage | Output | Location |
| --- | --- | --- |
| `read` | Loaded content | Memory, evictable (256 MiB budget) |
| `expand` (or `read`, for one item) | Items | Memory, evictable |
| `process`, collection `process` | Payload tables | DuckDB payload store |
| `analyze`, collection `analyze` | Metadata | Catalog columns |

A second availability bit is needed only if one stage's output can live in
different places for different rows.

## Decisions still needed

- Which typed outputs can satisfy downstream dispatch directly, and which need
  reconstruction or upstream recomputation.
