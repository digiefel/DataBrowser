"""A reproducible illustrative trace: two-level switching plus a Fourier 1/f realization.

Current is stored in µA. The supplied two-level component is known simulation
ground truth; this example does not claim to infer trap occupancy from a trace.
"""
function synthetic_trace(; n=1400, seed=61, seconds=0.125)
    rng = MersenneTwister(seed)
    t = collect(range(0, seconds; length=n))
    state = zeros(n)
    i, level = 1, 1.0
    while i <= n
        dwell = clamp(round(Int, randexp(rng) * 70), 10, 180)
        state[i:min(n, i+dwell-1)] .= level
        i += dwell
        level = 1 - level
    end
    phases = 2π .* rand(rng, n÷2)
    noise = [sum(sin(2π*k*(j-1)/n + phases[k]) / sqrt(k) for k in eachindex(phases)) for j in 1:n]
    noise .-= mean(noise)
    noise .*= 0.007 / std(noise)
    μ, amplitude = 2.67, 0.065
    rtn = μ .+ amplitude .* (state .- 0.5)
    raw = rtn .+ noise
    corrected = raw .- (rtn .- μ)
    edges = findall(!iszero, diff(state))
    candidates = [j for j in 2:length(edges)-2 if 20 < edges[j] < n-180]
    j = candidates[argmin([edges[k+2]-edges[k-1] for k in candidates])]
    a, b = max(1, edges[j-1]-15), min(n, edges[j+2]+15)
    (; t, raw, rtn, corrected, state, μ, amplitude, zoom=(t[a], t[b]), edge=edges[j], seed)
end
