# Curve fitting

Target design, curated on 21 October 2026. This plan owns fitting behavior and its numerical
contract. [Graphics](graphics-grammar.md) owns declarations; [processing](processing.md) owns
shared execution and [storage](storage.md) owns retained results. Fitting is one analysis operation,
not the organizing model for every workspace result.

Partly built. `DataBrowserFitting` holds the least-squares solver behind `fit(curve, starts;
xlim)` in `@plot`, which fits one curve for each group of points. Its result gives each parameter
as the estimate ± one standard error, from the covariance scaled by the residuals, and the
workspace keeps it until it closes. Bands, the methods `:covariance` and `:deltachi2`,
`fullrange`, the shared result contract and the connection to Core's cache are not built.

## Goal

Fit an ordinary Julia curve to selected measurements, inspect parameters and uncertainty, and
reuse the result in tables, labels, later calculations and code. Good defaults should reduce
manual tuning. No method can promise that every arbitrary curve will fit reliably without
appropriate starts, constraints or model knowledge.

## Agreed behavior

Davide agreed the following in the fitting discussion:

- The package is `DataBrowserFitting`, connected to Core. Plain-vector fitting also works without
  the browser. A plot-defined fit must not require a second unrelated `process`/`analyze`
  definition to make its result useful elsewhere.
- A named line of `@plot` has the form `name = fit(curve, starts; options...)`.
- The curve is an ordinary function of x with keyword parameters. Starts name fitted parameters;
  function introspection is not required.
- `name.field` exposes the current group's parameters, group values and drawn curve coordinates
  inside a declaration. Dependent lines draw once per group with its panel identity. Forward
  references and self-references in presentation expressions are supported in the intended form.
- By default the drawn curve spans fitted data; `xlim=(lo, hi)` chooses its drawn range and
  `fullrange=true` extends it to the axis limits. Display sampling must not silently change which
  observations are fitted.
- The band is on by default: `band=:confidence`, `band=:prediction` or `band=nothing`, with
  `level=0.95`. Confidence means a pointwise interval for the fitted mean curve; prediction also
  accounts for a new observation. The curve's form remains an assumption.
- Parameters are available in legend/text, Inspector and REPL. Automatic parameter text is the
  estimate ± one standard error. Confidence intervals separately retain their level and method;
  their half-width is not substituted for a standard error.
- `:covariance` and `:deltachi2` are the agreed method names. Their complete statistical and
  computational contracts are still under review.

## Reference declaration

This illustrates the agreed authoring direction, not a runnable claim for the future package:

```julia
resistance(gap; Rc, Rsh_W) = 2Rc + Rsh_W * gap

@plot data(measurements) * mapping(:gap_um, :R_ohm; color=:chip, col=:site) begin
    visual(Scatter)
    tlm = fit(resistance, (Rc=1.0, Rsh_W=1.0); xlim=(-10, 40)) *
        visual(Lines; label="$(tlm.chip): R_c = $(tlm.Rc) Ω")
    mapping(tlm.x[end], tlm.y[end]) * visual(Text; text="$(tlm.Rsh_W) Ω/µm")
end
```

The outside-declaration result access API is not decided. Earlier examples using
`tlm_plot.tlm`, native-model accessors or a particular result table remain proposals.

## Shared result contract to design

One retained numerical result should supply parameters, joint uncertainty, status, input count
and grouping information. Curves, bands, labels, legends, Inspector and REPL should read it.
Changing style or draw order must not solve again. Fit inputs, curve code, starts, fit domain and
weights must participate in invalidation. Sampling a curve or computing a more expensive interval
must be distinguishable from solving the point estimate.

A fit of one item's data and a fit over several items use the common item/group model. Generic
groups are now the chosen concept. A fit is a lazy computed value, one per part, as described in
[computations and their outputs](processing.md#computations-and-their-outputs); the
declaration-to-workspace execution API remains open.
Large native models, sample sets and grids need retained payloads; do not require every result to
be a scalar metadata column. Queryable summaries and native results must remain connected.

## Candidate options

These remain proposals, not settled API:

- Exact grouping/facet inference and overrides follow [graphics](graphics-grammar.md#shared-requirements).
  Useful inferred grouping with an override is required; its algorithm remains open.
- `fixed=(...)` for fixed parameters; `lower=` and `upper=` for explicit bounds. Starts and fixed
  parameters must be disjoint; omitted model defaults remain constants. Julia keyword errors
  alone are not a complete parameter schema or validation policy.
- `within=(lo, hi)` selects fitted observations while other points remain drawn. Drawing `xlim`
  is a separate option. The retained result records the actual rows used.
- `yerror` for known measurement errors; values carrying errors could supply them with an
  explicit independence approximation. Correlated fitted inputs need more than marginal errors.
- Ready-made curves with declared parameter/linear structure and useful starts.
- Per-panel legends built from group values, not reverse-engineered from colors.
- Automatic rounding of estimates/errors; the particular significant-digit policy is unchosen.
- Additional Monte Carlo/bootstrap methods and background refinement.
- Robust losses. Removing flagged/bad observations belongs in explicit data processing; a robust
  loss does not decide which measurements are valid.

## Numerical questions that remain open

The separate numerical review is consolidated here. The
[original review](archive/2026-10-21-discussion/fitting-review.md) preserves its counterexamples,
references and probe details.

### Model, objective and uncertainty

Specify known measurement errors versus an estimated common noise scale, weighting, objective,
constraints, degrees of freedom and interval assumptions in the result. Covariance, profile scans,
Monte Carlo and bootstrap are different methods with different assumptions; no universal ranking
is approved. The earlier formulas are proposals, not a blanket guarantee for arbitrary curves or
losses. Robust loss needs its own justified uncertainty contract.

The reviewed candidate distinguishes unrescaled known-error covariance from residual-scaled
unknown-common-error covariance, and normal from t/F-based thresholds where justified. Exact
linear-model statements need their assumptions; nonlinear intervals are generally approximate.
Choose and validate the full contract before exposing options as interchangeable.

Automatic text remains ± one standard error regardless of the confidence level. For asymmetric
profile intervals, a standard error may be unavailable. A constrained derived quantity needs its
own profile calculation; a profile interval's width is not its standard error.

### Bands and derived quantities

Confidence is pointwise unless explicitly specified otherwise. Prediction requires a rule for new
observation noise, including heteroscedastic data and extrapolation. A band must not imply that
model form or errors in x have been validated.

Retain joint covariance or shared samples for derived quantities involving several parameters;
independent marginal error propagation loses correlation. Repeated sweeps are not automatically
independent observations. Resampling choices need to reflect the input model.

Fit coordinate space on transformed axes is explicitly open: fitting raw values and fitting
log/displayed coordinates changes the objective. A logarithmic axis or AoG lowering must not
silently decide this contract. No raw-space or axis-space default has been chosen.

`fullrange` must not create an axis-expansion feedback loop. Zoom, display range and sampling
should not mutate the fitted observation set.

### Optimization and diagnostics

Multistart, parameter scaling, trust-region methods and variable projection are candidates.
Sampling a black-box function cannot prove global linearity or infer physical constraints.
The reviewed `a*b*x` counterexample rules out checking only unmixed derivatives. Negative
parameters may be valid arithmetic; domain constraints must be explicit.

Distinguish too few observations, rank deficiency, nonconvergence, a usable estimate with
unavailable uncertainty, and an exception in user code. Decide what dependent layers may draw
for each status and how unavailable values are shown. A diagnostic must not masquerade as a proof
of identifiability or a successful optimizer exit as proof of a valid model.

### Names, ownership and reuse

Resolve collisions between parameter names, group values and drawn fields such as `x`, `y`,
`lower` and `upper`. Declaration-time rejection and separate namespaces are alternatives, not a
chosen policy. Copy/retain mutable solver outputs before another solve can overwrite them.
All consumers must see one consistent result revision, including background interval refinement.

## Package evaluation and validation

CurveFit and direct NonlinearSolve use remain candidates. Compare documented public capabilities:
weighted/bounded solves, status, fixed parameters, derivatives, retained outputs and repeated
refits. Load time is not the main decision criterion. The archived source review records caveats
for the versions inspected; verify them against the chosen version before implementation.

Validation needs real SuperGaN and RuO2 analyses with the curve, selected rows, noise model and
known limits recorded. Do not make data-quality or fit claims from unconfirmed status flags.
NIST StRD is a proposed reference corpus; confirm the available files before claiming coverage.
Use small constructed cases for known failures and interval coverage, not as the whole test set.
The existing contract probe demonstrates selected counterexamples; it is not a solver benchmark
or verification of a complete real-data workflow.

The older proposal and coordination are preserved in the
[archive](archive/2026-10-21-discussion/fitting.md).
