# Node states

This document defines the state of one pipeline stage on one catalog row. Job
queues and payload storage use this state; they do not replace it.

The locations below describe the current rereadable-source implementation. Recovery/retention for
non-repeatable sources is still open; see
[Scientific workspace: analysis and acquisition](../scientific-workspace.md#source-contract-what-must-be-decided-early).

## Separate state

One enum cannot describe every relevant fact. Keep these parts separate:

- **Applicability:** whether the project has this stage for this row. A stage is
  absent when dispatch reaches the package's default method; Recipes answers
  from a registration whose callback is `nothing`.
- **Validity:** missing, stale, or fresh for one input revision.
- **Running:** whether a job for this stage is running now. The status does
  not record jobs that are waiting to start; only the job queue records those.
- **Failure:** the latest failure for the current revision, if any.
- **Blocked:** whether an input the stage needs failed or is blocked. No job
  can make the stage fresh until that input is retried or invalidated.
- **Output availability:** whether the output is present. Where it lives is
  fixed by the stage (below), so one bit is enough.
- **Revision:** the input revision a job read and an output represents.

`fresh` means the recorded successful result matches the current input revision. Output availability
is a separate fact: the payload may have been evicted, or a requester may need a reconstructed form.
Freshness does not mean that a job is running or that every requester can materialize its input.

## Required rules

- Invalidation increments the revision, marks the stage stale, and propagates
  downstream. It queues work only for stages that a request or the eager policy
  needs.
- A job captures its input revision. Completion publishes only if that revision
  is still current; otherwise the result is discarded.
- A failure belongs to one revision. It settles current request handles and
  blocks dependent work until retry or invalidation. Persist the failure and its
  revision. Reopening reuses it when inputs match; reopening alone is not a retry.
  Changed inputs invalidate successful and failed outcomes by the same rule.
- A persisted successful outcome is reusable only when its recorded input/code revisions match.
  Payload availability is checked separately against exact output references; presence at the
  same node and stage is insufficient after an interrupted buffered write. Missing or mismatched
  payload is not deliverable. It does not invalidate a retained downstream result merely because
  an upstream payload was evicted. Coordinate outcome and payload publication as roadmap 0.2.2
  requires.
- Evicting output clears availability and leaves validity unchanged. A consumer needing that
  payload follows the producer's recovery contract: load retained content, recompute repeatable
  work, or report unavailable input. It must not silently repeat acquisition. Current source
  fallback rereads missing input; that is not a general non-repeatable-source contract.
- Retry clears the current failure and queues the same revision. Invalidation
  clears failures from older revisions.

## Storage

Every row has exactly two stages, so one 64-bit word per row holds both, 32
bits each. A stage's half holds validity (2 bits), the running flag, the
failure flag, the blocked flag, output availability, applicability and a 24-bit
revision. The revision wraps after 16.7 million changes to one stage; a wrap is
harmful only if a single job runs across exactly that many changes.

The words live in `AtomicMemory`, one array per table. A reader loads a word
once and gets a consistent snapshot of both stages without a lock. Writers,
including the growth of the array when rows are added, hold the catalog's
write lock, so changes to status and to collection counters happen one at a
time. `AtomicMemory` has a fixed length: growth allocates an array of twice the
length, copies the words and replaces the array. A reader that still holds the
old array sees the words as they were a moment earlier. Failure messages are
text and rare; they live in a separate table under the same lock.

## Output location

| Stage | Output | Location |
| --- | --- | --- |
| `read` | Loaded content | Memory, evictable (256 MiB budget) |
| `expand` (or `read`, for one item) | Items | Memory, evictable |
| `process`, collection `process` | Payload tables, and metadata | DuckDB payload store; catalog columns |
| `analyze`, collection `analyze` | Metadata | Catalog columns |

Non-repeatable input retention and additional payload shapes will require revisiting these fixed
locations. The status encoding is an implementation choice, not a promise that every source can
recover an evicted value. Do not add new bits until the recovery/storage contract establishes what
information requesters actually need.

## Decisions still needed

- Which typed outputs can satisfy downstream dispatch directly, and which need
  reconstruction or upstream recomputation.
