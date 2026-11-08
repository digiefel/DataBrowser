# Prior art: how a group gets its members

Survey for the question in `docs/plans/groupings.md:56`. Sections 1 to 8 are facts, each with a
source. Section 9 holds the lessons; each one is labelled.

## 0. Four ways, in code

Four terms, each defined once:

- **explicit list**: someone stores the member ids.
- **rule**: a stored condition; the members are whatever meets it now.
- **key function**: each item computes a key; there is one group per distinct key.
- **producer**: a call returns groups as its result; its code decides which groups exist.

```
               which groups exist            the members
explicit list  whoever writes the list       the same person
rule           whoever writes the rule       the data, at each change
key function   the data (distinct keys)      the data
producer       the producing call            the producing call
```

```julia
# DataFrames.jl: key function; the result is a snapshot view of the parent
gdf = groupby(df, :k)
combine(gdf, :x => mean)                     # one row per group
transform(gdf, :x => (x -> x .- mean(x)))    # one value per member, from its group

# SplitApplyCombine.jl: key function over any iterable
group(i -> i.k, items)                       # dictionary: key => members
```
```sql
-- SQL: several levels of groups in one query
SELECT k, j, avg(x) FROM t GROUP BY GROUPING SETS ((k, j), (k), ());
-- window: each row gets a value from its partition; rows stay
SELECT id, x - avg(x) OVER (PARTITION BY k) FROM t;
```
```r
# ggplot2: groups are the interaction of the discrete aesthetics, or `group =`
ggplot(df, aes(t, x, colour = k)) + geom_smooth()   # one fit per k, kept inside the plot
```

## 1. Split-apply-combine

| System | Members and which groups exist | On change | Downstream; what got hard |
|---|---|---|---|
| DataFrames.jl | Key function. `GroupedDataFrame` stores the parent and one group index per row (`~/.julia/packages/DataFrames/0Y1g5/src/groupeddataframe/groupeddataframe.jl:37-48`). | Snapshot: "reflects the grouping of rows that was valid at its creation time"; it throws once the parent's row count changes (same file, 26-31). | `combine`: one row per group; `transform`: one value per row. |
| SplitApplyCombine.jl | `group`, `groupview`, `groupfind` ([github](https://github.com/JuliaData/SplitApplyCombine.jl)). | Recompute. | Groups are ordinary dictionaries of vectors. |
| dplyr | `group_by` stores the key columns on the table; `.drop` decides about empty factor levels ([docs](https://dplyr.tidyverse.org/reference/group_by.html)). | Recompute. | The grouping travels with the table; `summarise` removes one level by default. |
| pandas | Key function or `pd.Grouper`; `agg` versus `transform`. `observed=False` made a group for every category, even empty ([guide](https://pandas.pydata.org/docs/user_guide/groupby.html)). | Recompute. | Version 2.1 deprecated that default ([whatsnew](https://pandas.pydata.org/docs/whatsnew/v2.1.0.html)). |
| Polars | `group_by_dynamic` makes time windows that can overlap: one row in several groups ([docs](https://docs.pola.rs/api/python/stable/reference/dataframe/api/polars.DataFrame.group_by_dynamic.html)). | Lazy plan. | Membership is not always a partition. |
| xarray | `groupby`, `groupby_bins`, `resample`; `UniqueGrouper`, `BinGrouper`, `TimeResampler` describe a split as a value ([guide](https://docs.xarray.dev/en/stable/user-guide/groupby.html)). | Recompute. | The split description became a reusable value. |
| SQL | `GROUP BY`, `GROUPING SETS`, `ROLLUP`; `PARTITION BY` for per-row values ([PostgreSQL](https://www.postgresql.org/docs/current/queries-table-expressions.html#QUERIES-GROUPING-SETS)). | Recompute or maintain (section 4). | Nesting is a subset of key columns, never a group of groups. |

## 2. Grammar of graphics

| System | Members and which groups exist | Downstream |
|---|---|---|
| ggplot2 | Interaction of every discrete variable in the plot; `group =` overrides ([docs](https://ggplot2.tidyverse.org/reference/aes_group_order.html)). | Statistics run per group inside the layer; `layer_data()` gets them out. |
| AlgebraOfGraphics | `group(processedlayer)` groups by every scalar mapping: color, marker, layout, group (`~/.julia/packages/AlgebraOfGraphics/HY7hU/src/algebra/processing.jl:53-55`). | Analyses such as `linear()` run per group, only while drawing. |
| Vega-Lite | An aggregate groups by every non-aggregated field; `detail` adds a key with no visual channel ([docs](https://vega.github.io/vega-lite/docs/encoding.html#detail)). | Groups are implicit in the encoding. |
| Makie | No grouping: one plot call per series. | The user splits. |

Fact: DataBrowser's plot `aggregate` follows this pattern: one group per x and per categorical role,
inside the plot (`docs/plans/graphics-grammar.md:124-128`).

## 3. Tableau

Facts ([groups](https://help.tableau.com/current/pro/desktop/en-us/sortgroup_groups_creating.htm),
[sets](https://help.tableau.com/current/pro/desktop/en-us/sortgroup_sets_create.htm),
[set actions](https://help.tableau.com/current/pro/desktop/en-us/actions_sets.htm),
[LOD](https://help.tableau.com/current/pro/desktop/en-us/calculations_calculatedfields_lod.htm),
[order of operations](https://help.tableau.com/current/pro/desktop/en-us/order_of_operations.htm)):

- The dimensions in a view decide which groups exist: one mark per distinct combination.
- A group is an explicit map from dimension values to a label, often made by selecting marks. It
  becomes a new dimension.
- A set has in/out membership: fixed (explicit list) or dynamic (a condition or top N). A set action
  lets a selection replace, add or remove set values.
- `{FIXED k : AVG(x)}` computes at a stated grouping, independent of the view.
- What got hard: an order of operations decides which filter applies before which grouping.

## 4. Incremental group-by

| System | How it works | What got hard |
|---|---|---|
| Differential Dataflow | `reduce` on (key, value): one changed record updates only its old and new group ([mdbook](https://docs.rs/crate/differential-dataflow/0.11.0/source/mdbook/src/chapter_2/chapter_2_6.md)). | Membership must be a function of one record. |
| Materialize | SQL views maintained with Differential Dataflow. | Min, max, top-k need hierarchical reductions to avoid rescanning a group ([blog](https://materialize.com/robust-reductions-in-materialize/)). |
| DBSP / Feldera | Derives each operator's incremental form; sums per group update from the change alone ([arXiv](https://arxiv.org/abs/2203.16684)). | Other aggregates keep state per group. |
| Skip | Reactive collections by key; one accumulator per key ([github](https://github.com/SkipLabs/skip)). | Same shape. |

## 5. Incremental computation and build systems

| System | How outputs come to exist | What got hard |
|---|---|---|
| Salsa | A tracked function creates tracked structs. Identity: producing query, hash of fields not marked `#[tracked]`, occurrence counter ([docs](https://salsa-rs.github.io/salsa/plumbing/tracked_structs.html)). A rerun's stale structs are removed ([diff_outputs.rs](https://github.com/salsa-rs/salsa/blob/master/src/function/diff_outputs.rs)). | Identity is scoped by the producing query. |
| Nominal Adapton | The program names the nodes it allocates; names decide reuse across runs ([arXiv](https://arxiv.org/abs/1503.07792)). | Without names, reuse fails when positions shift. |
| Build systems à la carte | One key gives one value; dependencies static or found while running (Shake's `need`) ([JFP](https://www.microsoft.com/en-us/research/uploads/prod/2020/04/build-systems-jfp.pdf)). | An unknown number of outputs is outside the model. |
| Bazel | Outputs are declared before anything runs; an unknown number of files goes into one directory output ([docs](https://bazel.build/rules/lib/builtins/actions#declare_directory)). | Its files are invisible to the graph. |

## 6. Applications: explicit lists and rules side by side

| Application | Explicit list | Rule | What got hard |
|---|---|---|---|
| Lightroom Classic | Collections | Smart collections | A photo that fails the rule cannot be dragged in ([source](https://digitaljournalofphotography.com/difference-between-collections-and-smart-collections-in-lightroom-classic/)); cloud Lightroom has none ([forum](https://community.adobe.com/questions-680/smart-collections-and-lightroom-cc-909225)). |
| Apple Photos | Albums | Smart albums | Made on a Mac, they do not appear on iPhone ([Apple](https://support.apple.com/guide/photos/pht6d60a1f1/mac)). |
| Zotero | Collections, nested; an item in many | Saved searches store criteria | Saved searches cannot be nested ([forum](https://forums.zotero.org/discussion/112171/feature-request-put-saved-searches-into-collections)). |
| Gmail | Labels | Filters run on arrival and write labels | Old mail changes only on request ([help](https://support.google.com/mail/answer/6579)). |
| Finder | Tags | Smart folders | Files are never "in" them ([Apple](https://support.apple.com/guide/mac-help/mchlp2804/mac)). |

## 7. Scientific data systems

- openBIS: placement (Space, Project, Collection, Object) is explicit at registration; parent and child
  links are a separate many-to-many relation for provenance ([docs](https://openbis.readthedocs.io/en/20.10.0-11/user-documentation/advance-features/openbis-data-modelling.html)).
- NOMAD: users curate datasets from entries of many uploads; an entry can be in many datasets; after
  a DOI, entries can be added, not removed ([docs](https://docs.nomad-lab.eu/howto/manage/gui/upload.html)).
- ROOT: a `TChain` is an explicit list of files; `RDataFrame` has named `Filter` nodes in a lazy graph,
  filled in one pass ([docs](https://root.cern/doc/master/classROOT_1_1RDataFrame.html)).
- HDF5 and NeXus: the writer makes explicit groups; hard links put one object in several groups
  ([HDF5](https://docs.hdfgroup.org/hdf5/develop/_h5_g__u_g.html), [NeXus](https://manual.nexusformat.org/design.html)).
- Igor Pro: data folders form one tree; commands act on the current data folder
  ([docs](https://docs.wavemetrics.com/igorpro/igor-basics/data-folders)).

## 8. Visual dataflow and reactive notebooks

- Enso: `aggregate` with group-by columns returns one row per group; groups do not flow on
  ([Standard.Table](https://github.com/enso-org/enso/tree/develop/distribution/lib/Standard/Table)).
- KNIME: Group Loop Start runs a sub-workflow once per group; Loop End collects
  ([node](https://hub.knime.com/knime/extensions/org.knime.features.base/latest/org.knime.base.node.meta.looper.group.GroupLoopStartNodeFactory)).
- Orange: a Scatter Plot sends its selection downstream as "Selected Data"
  ([widget](https://orangedatamining.com/widget-catalog/visualize/scatterplot/)).
- LabVIEW: no group values; TDMS files have a file, group, channel hierarchy fixed by the writer
  ([NI](https://www.ni.com/en/support/documentation/supplemental/06/the-ni-tdms-file-format.html)).
- Pluto: a cell reruns when a variable it references changes ([plutojl.org](https://plutojl.org/)).
- Observable: `viewof` makes a brush selection a value other cells read
  ([Plot group](https://observablehq.com/plot/transforms/group)).

## 9. Lessons for DataBrowser

**1. Explicit lists and rules live side by side.** Fact: Lightroom, Photos, Zotero, Finder and
Tableau keep both kinds; none merges them (section 6). Proposal: the source and the GUI make explicit
lists; a `process` method on a group is a producer. A rule needs no third kind: it is a producer whose
call the catalog marks stale when its input changes.

**2. A rule that one program interprets does not travel.** Fact: smart albums do not reach an iPhone;
smart collections do not reach cloud Lightroom. Davide's objection to a rule "interpreted by the
workspace" (`docs/plans/archive/2026-10-21-discussion/groupings.md:3767`) matches this. Gmail shows a
middle path: a rule fires once and writes an explicit list.

**3. Snapshots are normal.** Fact: `GroupedDataFrame` keeps the grouping of its creation time.
Settled (`docs/plans/processing.md:102`): `members(group)` returns the members used to create the
group. Proposal: the catalog's stale state replaces DataFrames' row-count check.

**4. Cost per change depends on the shape of membership.** Fact: a key per record updates two groups
per change (Differential Dataflow). Fact: the toy's `HotGroup` is one call with the root as input
(`docs/plans/groups-toy.md:145-148`). In generic roles:

```julia
# shape of groups-toy.md: input = root; any change to any member of root reruns this call
process(::P, root::G0) = [G1(filter(m -> metadata(m)[:x] > 300, members(root)))]
```

Davide accepted reruns for a `process` method that reads all members. Fact: prior art makes one change
cost one call in two ways: a key per record (Differential Dataflow, `PARTITION BY`), or memoized inner
calls with names (Nominal Adapton). Question: at a million items, is a per-member condition such as
`HotGroup` the same case as a mean over all members?

**5. A producer's groups need ids that survive reruns.** Fact: Salsa and Nominal Adapton reuse work
only through stable identities; Salsa removes structs a rerun no longer creates. Davide's decision
(`docs/plans/groupings.md:110`): the project defines `id`; Core does not compose ids. Proposal: a
bin's id comes from its edges, not its position, so fits per bin keep their cache when a bin is added;
a vanished bin gets the state `removed`. Question: Salsa scopes identity by the producing query, and a
catalog lookup goes from an id to one call. What happens when two calls return a group with id `"hot"`?

**6. Whether empty groups exist is a default that is hard to change.** Fact: pandas changed it after
release. Question: does a producer's or a plot's group with no members exist?

**7. Members and inputs stay apart.** Fact: openBIS separates placement from parent and child links;
HDF5 hard links and NOMAD datasets make membership a graph. This agrees with the 3 November settlement.

**8. A GUI group is an explicit list that other calls read.** Fact: Tableau set actions, Orange
"Selected Data" and Observable `viewof` work this way. Proposal: a selection or a set of bins is a call
whose setting is the list of member ids; editing it makes its readers stale.

**9. Groups inside a plot stay inside the plot.** Fact: ggplot2, AlgebraOfGraphics, Vega-Lite and
today's DataBrowser `aggregate` keep groups inside drawing. Proposal: bins that a fit reads become
groups in the catalog, so a fit per bin is a workspace result.

**10. One engine, one order of operations.** Fact: Tableau and SQL fix a global order for filters,
groupings and windows. Proposal: when each group is a call with explicit inputs, the order is in the
inputs; no global order exists.
