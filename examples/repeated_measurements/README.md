# Compare measurements, then reuse the analysis

These are **target-design examples**. They show the code and interactions we want users to have,
and identify the steps the proposal cannot yet express. They are not runnable application examples.
Passing tests against the current implementation would not establish that this workflow works.

The analysis macro syntax below was invented by PM; it is not the external agent's proposal.
A1–A4 identify unanswered questions in that sketch, not defects established in the external design.
G1 is a workflow the external example does not demonstrate; its distinction between membership
and produced results is deliberate. G2 and G3 concern omissions in the external written example.
These observations have not established an overall verdict on the current design.

The group contracts
come from the external proposal. Neither is an implementation claim.
Canvas editing is outside this example.

## The task and data

Two samples have repeated measurements of current against time. The bundled files are small
synthetic traces:

```text
data/
├─ metadata.txt                 temperature_K: S1 = 280, S2 = 410
├─ S1/
│  ├─ repeat_a.csv
│  └─ repeat_b.csv
└─ S2/
   └─ repeat_c.csv
```

We want to inspect the repeats, calculate a mean for each sample, compare the means, and keep
using the result after closing its plot. Later, another measurement arrives and the analysis updates.

A person using the GUI should not need Julia to perform these common operations. A person or
agent using Julia should be able to obtain the same values and save the same analysis. A project
author should be able to make this the default analysis for every sample.

## 1. Open and inspect the measurements

The browser shows S1 and S2, their temperatures, and their measurements. Clicking S1 selects the
sample group itself. A separate action selects its measurements. A group is not shorthand for
silently selecting all its descendants.

This example starts with processed measurements already available. They may have been loaded
through DBRecipes or a native project. Source loading and project setup are outside this example;
the same analysis follows in either case.

The [type API example](type_api.jl) illustrates project-defined trace and group types. Users of
the shared analysis operations do not need to implement those types.

## 2. Compare the repeats of S1

The user selects S1's two measurements and chooses to show their curves and their average. The
GUI must be able to create the declaration shown in [analysis.jl](analysis.jl):

```julia
@analyze repeated_measurements(measurements) begin
    traces = data.(measurements)
    samples = trace_samples(traces)
    average = average_trace(traces)
    differences = difference_traces(traces, average)
end
```

The body receives native measurement values. `data` explicitly projects their payloads before
calling the [ordinary helpers](helpers.jl). Each assignment names a usable intermediate result.
A local variable inside a helper does not automatically become another workspace result.

The average of S1 has current values of 0.05, 0.7, 1.15, 1.4 and 1.6 µA. The inputs remain available
individually. Showing the average as a line does not turn the result into a plot-owned value.

**A1 — the input binding is not designed yet.** The candidate saved instance is:

```julia
@analyze sample_one = repeated_measurements(
    members(select(ws, ["S1/repeat_a.csv", "S1/repeat_b.csv"])))
```

The intended input set stays those two measurements when another tab or the REPL changes its
selection. Editing either source file should update the active calculation with its later value.
Previous completed results retain the versions they actually used.

Evaluating this expression once and saving its returned vector does not provide that behavior.
The selection/group contract and macro input adapter must specify how those identities and
versions are bound. The file also needs a defined workspace context when reopened. This is a
missing contract, not an instruction for the author to write a watcher.

**A2 — the shared result and view calls are missing.** `sample_one.average` names a result in
the macro candidate. The proposal must show the public operation that obtains its tracked value,
and the operation that gives that same value to a GUI view. The ordinary `traces_figure` helper is shown, but its application-facing binding is missing.
A reference to a calculation, its ordinary payload, and an AoG declaration are different things. We must not pass one as another
and claim the view API is finished.

## 3. Run the analysis for every sample

The type-API route in [type_api.jl](type_api.jl) lets a sample processing method produce a
`MeanTrace`. The result has its own identity, `mean/S1` or `mean/S2`, and retains its sample group.

```text
source root members:  S1, S2
process(S1) produces: mean/S1
process(S2) produces: mean/S2
```

A project author now wants one comparison of all the sample means, including future samples.
This apparently natural method does **not** obtain them under the proposed rules:

```julia
process(project, root::SourceGroup, means::AbstractVector{MeanTrace}) = compare_means(means)
```

**G1 — produced results are not later representations of source members.** The root contains
S1 and S2. `mean/S1` has a new ID, so it is not another version of S1. The typed member argument
therefore does not find it. The external proposal explicitly keeps that distinction.

We need one public expression that selects the completed mean outputs of these samples and binds
that changing set to later analysis. Manually clicking today's two means does not demonstrate
this automatic workflow. Giving the means their samples' IDs or adding every output to source
membership would change the model, not fill in a missing call.

## 4. Compare S2 with S1 and reuse the result

The comparison has two named roles: **reference = S1** and **measurement = S2**. Its data is
measurement minus reference. Reordering rows in a query must not reverse that sign.

```julia
@analyze sample_difference(reference, measurement) begin
    difference = difference_traces([data(measurement)], data(reference))
end

# Once G1 has a real public binding operation:
# @analyze S2_minus_S1 = sample_difference(mean_of_S1, mean_of_S2)
```

At the last sample time, this difference is 0.4 µA. It should appear in the current analysis's
results, expandable to its two inputs. Closing the plot must leave it usable from another file,
from the REPL and from the GUI.

**G2 — the external comparison example does not establish tracked work.** Its `Comparison`
type has no `id` method. Its `compare(selection)` call constructs a Julia value but shows no
publication/request boundary. Saying that it is tracked does not supply that boundary. The
ordinary author must not have to implement a new native result type just to save this comparison.
The external example does not yet show how an ordinary user saves this comparison without
implementing a native result type. The form of that operation remains open.

## 5. Change the inputs and come back later

These are review cases for the target workflow, not assertions about today's implementation:

| User action | What must remain understandable and usable | What the example must expose |
| --- | --- | --- |
| Change the shared REPL selection | The fixed S1 analysis keeps its two input identities | A1: fixed binding versus explicit following |
| Add a repeat to S1 | An analysis of all S1 members can include it; a fixed two-item comparison stays fixed | Group-membership binding versus an explicit ID list |
| Add sample S3 | The project-wide comparison can acquire its completed mean | G1: selection of produced results, not source members |
| Delete S2's only measurement but leave its directory | No new mean can be computed; the old mean is not silently presented as current input to a new comparison | Empty-output, retained-result and unavailable-input behavior |
| Move the same measurement into another displayed grouping | It remains the same measurement; walking two paths must not accidentally count it twice | The helper must choose distinct inputs or intentional multiplicity |
| Change the method used by a group | The next operation can show which exact input versions it used | G3: bound members versus actual invocation arguments |
| Change one saved instance's settings | Only that instance changes; editing a shared definition has a visible wider scope | Definition ownership versus instance settings |
| Close every plot, then reopen the saved analysis | Inputs, settings and named results can be recovered without rerunning unrelated top-level effects | Saved bindings, execution and public result access |
| Compare equal-length means sampled at different times | Require explicit alignment instead of subtracting by position | Matching array sizes alone does not establish corresponding samples |
| Replace a trace payload with an image or heatmap | Groups and provenance still work; the result need not be tabular | Generic native data is part of the target, even though today's store fails here |

**A3 — following needs an explicit form.** A view following the shared selection is an option,
not a hidden change to the meaning of a saved fixed instance. Independent tab selections remain
independent. Neither the shared input-binding API nor its saved syntax is complete yet.

**A4 — a vector payload is not necessarily several results.** `differences` above is ordinary
scientific data. Publishing one result per repeat requires an explicit operation. Generic
analysis must retain its contributing inputs without requiring the helper to return framework
carriers. The group-processing API's vector of native output items is a different contract.

**G3 — membership alone is not the complete computation trace.** The typed group method may
receive later member values than those retained by `members(sample)`. That distinction can be
valid. The user must be able to inspect the sample revision **and the exact supplied trace
versions** used for the mean. The proposal says Core records invocation inputs, but shows no
public access to that record. Expanding the sample's older members cannot be presented as the
complete answer.

## Other failures already present in the target walkthrough

The senior reviewer independently found these composition problems in the external proposal:

- In source metadata case 2, the directory reader requests
  `Union{SampleInfo, ItemA}` for every directory. Root members are sample groups, so they are
  filtered out. The root becomes empty and the hot-sample group cannot contain the hot samples.
- In the group toy, adding a two-argument
  sample `process` method does not replace its existing three-argument method. Both signatures
  remain. The example does not say which runs or prevent duplicate mean producers.
- Source metadata case 2 permits `ItemA.temperature = missing`, then calls the original process
  method whose result requires `Float64`. That preliminary call fails; it is not merely wasted
  work. The example must show how required metadata becomes available and how dependent work
  recovers, rather than relying on an unexplained convergence promise.

The three cases above are defects in the cited written examples. A1–A4 concern PM's own syntax;
they do not establish defects in the external proposal. G1 is an undemonstrated composition
workflow, while G2 and G3 identify omissions in the external example. The current image-storage
failure is implementation lag. These observations must remain separate.

The independent review also caught two errors in this example itself: the native sample initially
discarded its temperature metadata, and the difference helper checked no sample-time alignment.
Both are corrected in the shown code. That does not resolve the shared API gaps above.
