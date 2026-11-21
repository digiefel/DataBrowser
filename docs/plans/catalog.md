# The catalog in memory and in the cache file

[Architecture](../ARCHITECTURE.md) describes the catalog and cache built today, and the roadmap
item "Open a workspace with no work per item" in [0.2.3](../roadmap.md) tracks the work ahead. How
a workspace opens with no work per item, stores the whole catalog in the cache file, and runs rows
in batches remains open.

## Goal

- Opening a workspace takes constant time regardless of item count, doing no work per item, so the
  browser displays the previous session's tree, selection, and windows at once.
- Once a row is in memory, querying it costs no more than today: reading a Julia vector with no
  DuckDB query and no extra lock (plus checking whether that row has finished loading while the
  background load runs).
- Memory stays bounded. The numeric catalog fits in memory up to roughly 100 million items (and
  bounding it further waits until a project reaches a billion items); ids, labels, metadata, and
  errors stay in memory while their rows are active, and reading an evicted entry costs one query.
- Every workspace query runs at least as fast as when the entire catalog stayed in memory.
- Running project functions through the workspace costs little more than calling them in a plain
  loop: engine overhead per row stays small next to the cheapest `read` or `process`, requiring only
  a few hashes and writes without acquiring a shared lock per row.
- A failed row remains a cached result like any value, turning stale when its code, an input, or its
  source item changes, including changes made while the workspace was closed.

## Today

Today the cache file stores results while the catalog lives only in memory, so reopening a workspace
reruns the pipeline for every source item: adding its rows, recomputing revisions, looking up cached
results, and rebuilding id tables.

Seven catalog pieces are missing from the cache file:

- each row's inputs;
- the depth of a row that returned no value (such as a failed `process`), meaning how many calls
  preceded it in its chain;
- each source item's fingerprint, which enters only its `read` row's revision;
- each function's code revision;
- rows that never ran, such as `process` rows when background processing is off;
- each source item's members as returned by `members(source, item)`; and
- each group's member ids, which the cache currently stores inside serialized Julia values.

On the first opening, engine bookkeeping dominates the project's own functions: each job acquires
the catalog lock four times sequentially, capping throughput regardless of thread count. Meanwhile,
DuckDB buffers pages in memory up to `memory_limit` (1 GiB in the cache), yet every query from Julia
still costs at least 55 µs even from memory, and only integer keys are indexed so id lookups run
slower than key lookups.

## Proposal

Store the complete catalog in the cache file while keeping compact per-row numbers in memory and
bounded caches for active rows:

```text
                      in the cache file                         in memory
    per row           computation id, depth, state, revision,   state, function, revisions,
                      revision of the result, type, error,      inputs and readers, as numbers:
                      inputs                                    ≈ 35 B
    per value         id, row, label, type, members, metadata   id → key: ≈ 20 B
    per source item   id, fingerprint, members
    per function      code revision                             code revision
    per row in use                                              priority and requests; ids,
                                                                labels, metadata, errors and
                                                                values, in caches of bounded size

    ≈ 130 B per item (estimate): 130 MB at a million items, 13 GB at 100 million, 130 GB at a billion
```

Because each job reads row states, inputs, and downstream readers repeatedly, those numeric arrays
live in Julia vectors indexed by row key, answering in nanoseconds instead of DuckDB's 55+ µs.
DuckDB handles bulk queries across many rows — filters, sorts, and counts — in one query each.

On startup, opening follows this sequence:

```text
    open the file                                    nothing per item
    load the rows that the last session showed:      a few queries
      the tree, the selection, the windows             → the browser shows them
    then, in the background:
      load the numbers of every row in one scan      13 ms for 3 columns of 400,000 rows
      compare the code revision of each function     one comparison per function
        with the saved one                             → the rows of a changed function become stale
      walk the source and compare each fingerprint   one fingerprint per source item, compared with
        with the saved one                             the saved ones in one query
                                                       → the rows of a changed source item become
                                                         stale; a new source item adds rows; a
                                                         missing one removes its rows
```

Any question touching a row that has not loaded yet pulls that row to the front of the background
load and waits for one query. Compared with loading the full catalog up front:

```text
                                  whole catalog at open      this proposal
    startup                       ≈ 1 µs per item            constant time
    first read of a row           0                          shown rows load first: a few ms
    later reads                   memory                     memory
    bulk work (e.g. editing       memory, after full load    one scan, matching that load cost
      `read`)
    writes                        the same rows              the same rows
```

### Running rows

Instead of locking row by row, a worker claims a batch of rows sharing one function — such as 1,000
calls to `process(project, x)` for items `x` of one type — in a single lock acquisition:

```text
    today, for each row                           proposed, for each batch of rows of one function
      take the lock: count the end of the last      take the lock: claim up to N rows
        job, take the row
      take the lock: compute the revision           compute the N revisions, outside the lock
      call the function, one dynamic dispatch       call the function N times in one loop,
                                                      compiled for their types
      take the lock: save the time of the call
      keep the result in its store                  keep the N results: one call to the store
      take the lock: save the record, update the    take the lock: write the N states and
        tables by id, spread to the readers           revisions, update the tables by id, spread
                                                      to the readers
                                                    save the N records: one write to the cache

    target (estimate): under 1 µs of the engine's own work per row
```

If one function call throws, its own row fails while the rest of the batch continues. Batches shrink
when a window or script requests rows so interactive work never waits behind a large batch.

## Steps

Each step ends with a measured benchmark change:

1. Persist the full catalog in the cache file so reopening builds the catalog from DuckDB instead of
   rerunning the pipeline, then check code revisions and fingerprints in the background. Measured:
   second-opening time per item.
2. Shrink the in-memory catalog to numeric columns, rebuilding each computation from the cache file
   only when its row runs. Measured: memory per item.
3. Execute rows in type-uniform batches per function. Measured: first-opening time per item against
   a direct loop calling the same functions at 10 threads and at 1 (adding that loop to the
   benchmark).
4. Load the catalog in the background, prioritizing the rows shown in the previous session. Measured:
   time to first frame, which must no longer grow with item count.
5. Evict ids, labels, metadata, and errors outside active row caches, querying the cache file in
   batches for the tree, status line, and full selection (today rebuilding the tree sorts every
   top-level item by label, and the status line scans every error).
6. At a billion items, bound the catalog's numeric columns in memory too.

## Open questions

- Before the background source walk completes, the workspace holds only the id of each `read` row's
  source item; either the source supports lookup by id, or a `read` row that needs to run waits for
  the walk.
- Project method definitions determine which rows exist (for example, `process(project, g, members)`
  controls group-process rows), so the cache file must record enough method information for reopening
  to detect added or removed methods while the workspace was closed.
- In an id-to-key table storing only hashes, two out of a billion ids collide under a 64-bit hash
  with ~3% probability; either matches must verify against the file, or the hash must be wider.
- Because cache writes happen every 2 s, up to 2 s of rows rerun after a crash, as today.
- Sorting top-level tree items by label when millions of items sit at the top remains open.
- Because stores currently write one item at a time via `write(store, key, item)`, batch writes will
  extend the store contract.
