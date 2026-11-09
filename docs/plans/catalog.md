# The catalog in memory and in the cache file

Proposal of 5 November 2026, delayed: Davide asked for the plan, and the change waits.
[Architecture](../ARCHITECTURE.md) describes the running system. The roadmap entry "Open a
workspace with no work per item" in [0.2.3](../roadmap.md) tracks the change.

## Goal

- Opening a workspace takes the same time for any number of items: it does no work per item. The
  browser shows the tree, the selection and the windows of the last session at once.
- Once a row is in memory, a question about it costs no more than with today's catalog: a read of
  a Julia vector, with no query and no lock that today's catalog does not take. Until the
  background load ends, the question also checks whether its row is loaded.
- Memory stays bounded. The catalog is small enough to stay whole in memory up to about 100 million
  items; bounding the catalog too waits until a project needs a billion items. Ids, labels,
  metadata and errors stay in memory while their rows are in use; a question about one that left
  memory costs one query.
- Each question to the workspace is at least as fast as with the whole catalog in memory.
- Running the project's functions through the workspace costs little more than a loop, written by
  hand, that calls them. The engine's own work for each row stays small next to the cheapest `read`
  or `process`: a few hashes and writes, and no take of a shared lock for each row.
- A failed row stays a result, as a value is. A row still becomes stale when its code, an input or
  its source item changes, also when the change happened while the workspace was closed.

## Today

Measured on 5 November 2026 with the bench project of `bench/workloads.jl`: items of one table row,
10 Julia threads, an M1 Pro. These figures predate commit `87f9681`, which keeps the metadata of
items only in the cache file and the table `items`, so the records of the cache in memory no longer
hold it.

The cache saves results, and not the catalog. So each open runs the pipeline again for every
source item:

```text
    second open                     40,000 items   400,000 items
      read 3 cache tables whole         0.4 s          5.7 s
      run the pipeline again            1.0 s         14   s    for each source item: add its rows,
                                                                compute their revisions, find the
                                                                saved results, rebuild the tables
                                                                by id
      total                             1.6 s         20.8 s
```

The engine's tables take about 4.5 KB of memory per item, without the project's own objects, at
40,000 items with 3 rows each:

```text
    rows of the catalog                   930 B per item
    computation id → key, as text         880
    computation → row                     660
    cache: saved records                  610
    values that rows gave                 490
    cache: keys of values                 200
    10 other tables                       720
```

The cache file lacks these parts of the catalog:

- the inputs of each row;
- the depth of a row that gave no value, such as a failed `process`: the number of calls before
  it in its chain of calls;
- the fingerprint of each source item, which only enters the revision of its read row;
- the code revision of each function;
- the rows that never ran, such as each `process` row without background processing;
- the members of each source item, as `members(source, item)` gives them;
- the members of each group as ids: the file saves them as serialized Julia values.

The first open runs the project's functions, and the engine's own work costs far more than the
calls. With `background_processing=true`, a `read` and a `process` that return prepared values, and
40,000 items:

```text
    a threaded loop that calls read and process      0.14 µs per item
    the workspace                                    163   µs per item, about 1,200 times the loop
      of which the catalog lock is held               97   µs per item, by one worker at a time
```

Each job takes the catalog lock four times and holds it for 48 µs in all. Only one worker holds it
at a time, so the workspace runs at most about 20,000 jobs per second, for any number of threads.
Inside the lock, a finished row spends 23 µs on the tables by id (`finished!`) and 10 µs on the
records of the cache.

DuckDB keeps the pages of the file that it read in memory, up to `memory_limit`, which the cache sets
to 1 GiB. A query from Julia still costs at least 55 µs, also when its pages are in memory. One row
by key takes 200 µs, 100 rows by key 2 ms, and one column of 400,000 numbers 13 ms. Only the keys
have indexes, so one query by id takes 1 to 6 ms.

## Proposal

The cache file holds the whole catalog. Memory holds the numbers of each row, and caches of the
rest for the rows in use:

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

Each job reads the state, inputs and readers of rows many times, so these live in Julia vectors at
the position of the row's key. A Julia vector answers in nanoseconds, and DuckDB in 55 µs or more.
DuckDB answers the questions over many rows, such as a filter, a sort or a count, in one query each.

When a workspace opens:

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

A question about a row that is not loaded yet moves the row to the front of the load and waits for
it: one query. Compared with loading the whole catalog before the workspace is usable:

```text
                                  whole catalog at open      this proposal
    open                          ≈ 1 µs per item            nothing per item
    first look at a row           0                          the rows shown load first: a few ms
    later looks                   memory                     memory
    work over many rows, such     memory, after the load     one scan, at the cost of that load
    as a code change of `read`
    writes                        the same rows              the same rows
```

### Running rows

A worker takes a batch of rows of one function, such as 1,000 rows of `process(project, x)` for
items `x` of one type, in one take of the catalog lock:

```text
    today, for each row                           proposed, for each batch of rows of one function
      take the lock: count the end of the last      take the lock: take up to N rows
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

A function that throws fails its own row, and the other rows of the batch go on. A batch is
smaller when a window or a script requests rows, so that a requested row does not wait behind a
large batch.

## Steps

Each step ends with a measured change.

1. The cache file saves the whole catalog, and the open builds the catalog from the file instead
   of running the pipeline again. Then code and fingerprints are checked in the background.
   Measured: the second open, 40 µs per item today.
2. The catalog keeps numbers only: rows as columns of numbers, and each computation rebuilt from the
   file when its row runs. Measured: memory per item, 4.5 KB today.
3. Rows run in batches of one function. Measured: the first open per item against the loop that
   calls the same functions, 163 µs against 0.14 µs today, at 10 threads and at 1. The benchmark
   gains that loop, so that each run shows both.
4. The open loads the catalog in the background, the rows that the last session showed first.
   Measured: the time to the first frame, which then does not grow with the number of items.
5. Ids, labels, metadata and errors leave memory, except for the caches of rows in use. The tree,
   the status line and selecting all items ask the file in batches. Today, each rebuild of the
   tree sorts every item at the top by label, and the status line goes through every error.
6. At a billion items: the catalog's numbers in memory are bounded too.

## Open questions

- A read row needs its source item to run, and before the walk the workspace has only the id of
  the source item. Either the source gives a source item by its id, or a read row that must run
  waits for the walk.
- The methods that a project defines also decide which rows exist: without a method
  `process(project, g, members)`, the catalog has no group process rows. A method added or removed
  while the workspace was closed must add or remove those rows, so the file saves what the open
  compares.
- A table from id to key that keeps no ids: two of a billion ids have the same 64-bit hash with a
  probability of about 3 %. Either each match is checked against the file, or the hash is longer.
- The file is up to 2 s behind memory, the interval between two writes of the cache. After a crash,
  the rows of those 2 s run again, as today.
- The order of the tree by label, with millions of items at the top.
- A store saves one item for each call of `write(store, key, item)` today. Keeping a batch in one
  call changes the store contract.
