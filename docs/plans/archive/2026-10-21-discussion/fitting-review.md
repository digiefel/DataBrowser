# Fitting review — 2026-10-20

The declaration is a useful direction. The numerical and result contracts are not ready to implement.
Keep `fit(curve, starts; ...)`, keyword parameters, named results within `@plot`, and the default
band. Resolve the items below before treating the plan as an implementation specification.
This is a review, not a replacement for Davide's agreed choices. No production code changed.

## Purpose and syntax

Keep the physical parameter names and ordinary keyword-argument model. A fit declared beside
observations and result-derived graphics is useful; a second fitting language is unnecessary.
Keep `tlm.Rc` within the declaration and the named table outside, but specify evaluation timing
and whether the table is a completed snapshot. They are different scopes, not mutable globals.

The purpose should be "fit selected observations and expose estimates, assumptions and uncertainty
consistently", rather than "any function works without tuning". Built-in model knowledge can improve
defaults without pretending to infer physics from arbitrary code.

Explain `within`, `xlim` and `fullrange` with one example: fit observations in [0,0.5], draw the
fitted model over [-0.1,0.8], and keep the viewport independent. State original-coordinate units,
endpoints and precedence. A log axis must not silently turn the fit into log-y regression.

Remove "No file is involved" and raw keyword-dispatch error examples: neither explains the
scientific behavior, and the browser's source remains durable. State what free/fixed parameters
are, how failed groups remain inspectable, and what the reported uncertainty means.

## Findings, in implementation order

| Priority | Problem in fitting.md | Required change |
|---|---|---|
| Blocking | Lines 95–104 promise structure/physical information that cannot be recovered reliably from arbitrary functions. `a*b*x` has zero separate second derivatives but is not jointly affine; negative `tau` in `exp(-x/tau)` is numerically valid. A full-rank local Jacobian does not rule out global ambiguity (`a^2*x` has the same prediction for ±a). Units do not supply numerical scales. | Replace guarantees with bounded numerical diagnostics. Explicit starts/bounds/scales remain available; built-in models may supply declared structure and good guesses. No automatic variable projection for a black-box curve. Detecting bad trial evaluations must not invent physical constraints or swallow arbitrary callback bugs. |
| Blocking | Lines 112–125 mix standard errors, confidence intervals, known observation errors and estimated noise. MINOS, F-based profiling and covariance are not interchangeable methods of increasing accuracy. | Specify the objective, noise assumptions, meaning/level of intervals and conditions where each method applies. Preserve the agreed names. A nonlinear profile interval is not automatically exact or better. See the equations below. |
| Blocking | The prediction-band column describes refitted mean curves, which omit new-observation noise. The default confidence band is also described as where the true curve lies, without pointwise/simultaneous semantics. | Define default confidence shading as pointwise intervals for the mean response conditional on the model. Prediction intervals add observation noise. With heteroscedastic `yerror` known only at measured x, a prediction interval at arbitrary/extrapolated x needs a noise rule; do not invent interpolation silently. Profiling f(x) at a few points is not a specified band algorithm. |
| Blocking | `fit(...) * visual(Lines)` promises a default band; results also appear in dependent layers, the Inspector and a REPL table. No retained result/lowering contract is specified. `fullrange` can depend on limits that fitted layers themselves change. | Compute one owned fit result per group; all consumers use it. Separate solving, uncertainty and display sampling. Solve axis extent/range policy before sampling, with fit samples excluded from expanding their own x domain. A compound curve/band renderer must use documented public APIs. Never refit through AoG, scrape a rendered plot, or reconstruct groups from colors. |
| High | Lines 49–55 and 66–79 leave parameter/group ownership ambiguous. Julia call validation is not parameter-schema validation; `kwargs...` accepts extras and defaults hide omissions. `tlm.x`, a fitted parameter x and a grouping column x collide. Continuous color cannot automatically create one fit per distinct value. | Starts/fixed values explicitly define the free/fixed parameter schema, with deterministic ordering and no overlap. Curve defaults not named there are constants, not secretly fitted. Set a collision rule before exposing fields. Preserve categorical grouping and facet identity; continuous aesthetics do not split groups. Resolve dependencies and joins by group keys; do not zip result arrays. |
| High | Lines 80–82 make a new number type sound like a printing feature. Arithmetic must preserve covariance or shared samples; marginal asymmetric interval endpoints are insufficient to propagate a derived quantity. | Separate estimate, uncertainty representation and display. Define what `$(tlm.Rc)` and `round(tlm.Rc; digits=...)` mean before choosing a number type. Retain joint covariance/shared samples. Profile a derived quantity as its own constrained inference problem, or explicitly report that uncertainty as unavailable. Do not fabricate it from marginal endpoints. |
| High | Lines 85–86 collapse bad inputs, failed optimization and unavailable uncertainty into missing values. Ordinary `"$(missing)"` prints "missing"; `tlm.x[end]` may throw. n=p and rank-deficient n>p are missed. | Retain every group's status, reason, included rows, point count and residual degrees of freedom. A valid point estimate can coexist with unavailable uncertainty. Gate dependent drawing before evaluating expressions for failed groups; specify skip/placeholder behavior without globally changing Julia interpolation. Distinguish user-code errors from expected numerical failures. |
| High | Style-only changes must not refit, but x/y in the result mean display samples; background uncertainty work may replace published results; cached solver objects can alias mutable arrays. | Define a completed result snapshot and revision. Data/model/start/domain/weight changes invalidate fitting; style does not. Sampling range/grid changes do not invalidate coefficients, though they may require new interval evaluations. Publish coherent snapshots and reject stale background completions. Copy or otherwise own data retained from reusable caches. |

## Statistical contract to write down

Let n be the included observations, p the free parameters, ν=n−p, r=y−f(x;θ).

- With known, independent measurement standard deviations σᵢ, minimize
  Q=Σ(rᵢ/σᵢ)². Do not rescale its covariance to force reduced χ² to one. For regular one-parameter
  profiling, use Q(θⱼ)−Qmin ≤ χ²₁(level); the nonlinear coverage claim is asymptotic.
- With unknown common Gaussian variance, minimize S=Σrᵢ² and estimate s²=Smin/ν when ν>0.
  The one-parameter F-based profile uses (S(θⱼ)−Smin)/(Smin/ν) ≤ F₁,ν(level).
  This gives exact intervals for the regular unbounded linear model; it is approximate generally.
- Covariance uses the same residual and noise model. Known-noise linear inference uses normal
  quantiles; estimated-noise linear inference uses Student t. A Jacobian Gauss–Newton covariance
  is not generally the full objective Hessian computed by HESSE.
- A standard error is not a 95% interval half-width. For four observations and two parameters,
  the two-sided 95% t multiplier is 4.30265, not one. `level` and the printed ± need an explicit contract.
- Mean-response variance is gᵀΣg. New-observation prediction variance also includes σnew².
  Bounds, poor rank, model misspecification, correlated residuals and data-dependent region choice
  limit interpretation. A high r² or agreement of solvers does not establish physical validity.

Sources: [MINUIT uncertainty semantics](https://scikit-hep.org/iminuit/notebooks/hesse_and_minos.html),
[lmfit's F profile](https://lmfit.github.io/lmfit-py/confidence.html),
[NIST residual variance](https://www.itl.nist.gov/div898/handbook/pmd/section4/pmd431.htm),
[NIST prediction intervals](https://www.itl.nist.gov/div898/handbook/pmd/section5/pmd512.htm).
These support different conditional calculations, not a universal ranking of methods.

## Package choice: judge the contract, not feature count

Keep the fitting agent's public-API and correctness criteria. Remove automatic structure detection
from the initial requirements. First verify a keyword-model adapter with explicit free/fixed
parameters, weighted bounded solves, termination reporting and stable retained results.

CurveFit 1.11.5 is a plausible first adapter; direct NonlinearSolve is justified if its documented
problem API materially simplifies what we must own. A keyword-to-vector wrapper is ordinary
Julia, not a hack. Changing a profile's free-parameter set also works through a new residual wrapper;
it does not require introspecting Julia methods. Cache reuse must respect changed dimensions.

Installed-source checks agree with the [CurveFit documentation](https://docs.sciml.ai/CurveFit/stable/api/solutions/):
`vcov` defaults to relative-sigma rescaling; the plan's true `yerror` policy requires
`absolute_sigma=true`. Its `margin_error` uses t even with that flag, so calling `confint` blindly
does not implement the known-noise normal contract above. `reinit!` requires unchanged input sizes;
returned solutions may retain arrays modified by cache reuse. The package's transformed exponential
and power algorithms change the residual objective: log-space fitting is not a harmless faster
implementation of original-y least squares. See its [solver contracts](https://docs.sciml.ai/CurveFit/stable/api/solvers/).
No solver timing or package comparison was executed in this review.

## A sound implementation sequence

1. **Fit independently of drawing.** A normal Julia model adapter accepts explicit parameters and
   prepared observations in original physical coordinates. Validate aligned finite x/y/σ, positive
   σ, bounds/fixed-name consistency and rank/termination. Retain input identity and exclusions.
2. **Retain results.** Parameters, joint uncertainty, diagnostics, status and group/facet keys belong
   to one completed result. Consumers cannot trigger another independent fit. Internal types need
   not become a family of public constructors.
3. **Lower the existing declaration to that operation.** Resolve named dependencies before running,
   preserve source spans, and bind each result to the corresponding categorical group. Drawing is
   a consumer. Prove curve, band, text and Inspector all refer to the same result/revision.
4. **Add uncertainty by defined method.** Start with transparent linear/covariance semantics; implement
   :deltachi2 against the stated objective and supported constraints, not generic "better errors".
   Keep default bands, but report unavailable intervals honestly. Then add reproducible resampling.
5. **Validate the GUI task.** Select/compare real measurements, select a fit region, add the fit,
   inspect and export it. An explicit Add fit action may insert code, as Davide clarified; inline
   controls still patch only values. Preserve user source and zoom.

This order reduces numerical uncertainty before adding UI machinery. It does not reduce the
intended feature set or replace the agreed declaration syntax.

## Evidence and validation

Small, executed Julia counterexamples are in
[work/gui-editing/fitting-contract-probe.jl](../../work/gui-editing/fitting-contract-probe.jl).
They establish specific contract failures, not solver performance or model coverage:

- Joint-linearity counterexample: separate curvature 0, mixed curvature 1.
- Full-rank two-point line: coefficients [1,2], ν=0, residual variance NaN; repeated x instead has rank 1.
- A naive result/parameter merge silently overwrites x.
- A simple prediction variance is 0.25 with covariance, 2.75 if parameter errors are treated independently.
- Missing keyword/default, extra kwargs, missing interpolation and failed-result field access behave as described.

Use real IV/TLM/R(T) data to validate the intended workflow, plus NIST certified regression data
for numerical reference. A dataset count is not coverage. Record model, selected rows, units,
noise assumption and reference accuracy per case. Agreement between starts/solvers and a good
picture are diagnostics, not ground truth. Check residual patterns, sensitivity to the selected
region, parameter identifiability and physical plausibility. A few small controlled cases remain
necessary for known failure conditions and interval coverage; they complement real data.

Real-data preparation check: the first SuperGaN probe fits two sweeps whose 40 rows all have
Status=4. Their meaning is not established here; interpret flags before drawing physical
conclusions. Separate sweeps do not establish independent replicas. The probe currently has
only Site=L, but drops Site from its derived table; preserve it before extending the corpus.
First-stage fitted R errors are estimated, possibly correlated uncertainties, not automatically
known independent `yerror` for a second-stage TLM fit.

No NIST datasets downloaded, production changes, package tests, full benchmark run or commits.

## Decisions needed before parameter presentation

1. **Resolved by Davide, 2026-10-20:** `$(tlm.Rc)` prints the estimate ± one standard error.
   Confidence intervals are exposed separately with their level and method. A profile interval
   must not be relabeled as a standard error; unavailable standard errors stay unavailable.
2. Which first real IV dataset/model/range should establish the selected-region workflow? The
   plotting/fitting code must consume its actual data and identities, not a reconstructed example.
