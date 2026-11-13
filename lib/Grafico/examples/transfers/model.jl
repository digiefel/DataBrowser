# Private experiment: no names in this file are a proposed authoring API.

struct Contribution{I,G,O}
    source_id::I
    group::G
    value::Float64
    weight::Float64
    order::O
end

struct TransferPlan{C,G}
    contributions::Vector{C}
    groups::Vector{G}
    releases::Vector{Float64}
    arrivals::Vector{Float64}
    slots::Vector{Float64}
end

"""Keep observation identity and reduction membership independently of storage order.

The callbacks extract ordinary row fields. Binning is only one possible `group`.
Weights describe contributions; values describe the quantity being reduced.
"""
function transfer_plan(rows; id, group, value, weight = _ -> 1.0,
                       order, groups = nothing, flight_duration = 0.18)
    isempty(rows) && throw(ArgumentError("The experiment needs at least one observation."))
    0 < flight_duration <= 1 || throw(ArgumentError("flight_duration must be in (0, 1]."))

    members = map(rows) do row
        Contribution(id(row), group(row), Float64(value(row)), Float64(weight(row)), order(row))
    end
    length(unique(c.source_id for c in members)) == length(members) ||
        throw(ArgumentError("Observation IDs must be unique."))
    all(c -> isfinite(c.value) && isfinite(c.weight) && c.weight >= 0, members) ||
        throw(ArgumentError("Values must be finite and weights finite and nonnegative."))

    # The identity tie-break makes tied acquisition/order values reproducible too.
    sort!(members; by = c -> (c.order, string(typeof(c.source_id)), repr(c.source_id)))
    keys = groups === nothing ? unique(c.group for c in members) : collect(groups)
    length(unique(keys)) == length(keys) || throw(ArgumentError("Group keys must be unique."))
    all(c -> c.group in keys, members) || throw(ArgumentError("A contribution has no output group."))

    releases = collect(range(0.0, 1 - flight_duration; length = length(members)))
    arrivals = releases .+ flight_duration
    # A single observation starts immediately and still finishes at progress 1.
    length(members) == 1 && (arrivals[1] = 1.0)

    totals = Dict(key => 0.0 for key in keys)
    slots = map(members) do c
        slot = totals[c.group] + c.weight / 2
        totals[c.group] += c.weight
        slot
    end
    TransferPlan(members, keys, releases, arrivals, slots)
end

smoothstep(x) = x * x * (3 - 2x)

"""Sample a complete frame from progress alone, including all sufficient statistics."""
function sample_transfer(plan::TransferPlan, progress::Real)
    isfinite(progress) || throw(ArgumentError("Progress must be finite."))
    p = clamp(Float64(progress), 0.0, 1.0)
    local_progress = [
        smoothstep(clamp((p - release) / (arrival - release), 0.0, 1.0))
        for (release, arrival) in zip(plan.releases, plan.arrivals)
    ]
    arrived = BitVector(p >= arrival for arrival in plan.arrivals)
    counts = zeros(Int, length(plan.groups))
    mass = zeros(length(plan.groups))
    weighted_sum = zeros(length(plan.groups))
    group_index = Dict(key => i for (i, key) in enumerate(plan.groups))

    for (c, is_arrived) in zip(plan.contributions, arrived)
        is_arrived || continue
        j = group_index[c.group]
        counts[j] += 1
        mass[j] += c.weight
        weighted_sum[j] += c.weight * c.value
    end
    means = [mass[j] == 0 ? missing : weighted_sum[j] / mass[j] for j in eachindex(mass)]
    (; progress = p, local_progress, arrived, counts, mass, weighted_sum, means)
end

"""Expose completed output groups after computing the full-data statistic."""
function sample_output_exposure(plan::TransferPlan, progress::Real)
    full = sample_transfer(plan, 1)
    visible = floor(Int, clamp(progress, 0, 1) * length(plan.groups))
    [j <= visible ? full.counts[j] : 0 for j in eachindex(plan.groups)]
end

"""Use each view's identity without changing the underlying observation identity."""
mark_keys(plan::TransferPlan, view_id) = [(view_id, c.source_id) for c in plan.contributions]

"""A derived lag observation retains both source identities, in acquisition order."""
function paired_observations(plan::TransferPlan, lag::Integer)
    1 <= lag < length(plan.contributions) || throw(ArgumentError("Lag must leave at least one pair."))
    [
        (id = (a.source_id, b.source_id), sources = (a.source_id, b.source_id),
         x = a.value, y = b.value)
        for (a, b) in zip(plan.contributions[1:end-lag], plan.contributions[1+lag:end])
    ]
end

"""A geometric flight evaluated at local progress; coordinates may be pixels or data."""
function flight_position(source, target, progress; bend = 0.12)
    u = clamp(progress, 0, 1)
    dx, dy = target[1] - source[1], target[2] - source[2]
    arc = 4u * (1 - u) * bend
    ((1 - u) * source[1] + u * target[1] - arc * dy,
     (1 - u) * source[2] + u * target[2] + arc * dx)
end
