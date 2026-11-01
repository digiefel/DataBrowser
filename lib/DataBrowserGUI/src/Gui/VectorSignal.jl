using FFTA: rfft, irfft

"""Prepared one-sided spectrum, Hann periodogram and normalized autocorrelation of a real vector."""
Base.@kwdef struct VectorSignal
    frequency::Vector{Float64} = Float64[]
    amplitude::Vector{Float64} = Float64[]
    psd::Vector{Float64} = Float64[]
    lag::Vector{Float64} = Float64[]
    correlation::Vector{Float64} = Float64[]
    issue::String = ""
end

"""
Compute a one-sided FFT amplitude spectrum, a one-sided Hann-windowed periodogram, and biased
autocorrelation normalized to one at zero lag. `spacing` is the distance between samples.
`remove_mean` applies to the spectra; autocorrelation always uses centered values. Nonfinite
samples are rejected rather than removed, since removing them would change the sample spacing.
"""
function vector_signal(values::Vector{Float64}, spacing::Float64; remove_mean::Bool=true)::VectorSignal
    isfinite(spacing) && spacing > 0 || return VectorSignal(issue="Sample spacing must be finite and greater than zero.")
    n = length(values)
    n >= 2 || return VectorSignal(issue="Frequency Analysis needs at least two samples.")
    all(isfinite, values) || return VectorSignal(issue="Frequency Analysis needs finite samples. Removing NaN or Inf would change the sample timing.")
    centered = values .- mean(values)
    signal = remove_mean ? centered : values
    frequency = collect(0:fld(n, 2)) ./ n ./ spacing
    amplitude = abs.(rfft(signal)) ./ n
    interior = 2:(iseven(n) ? length(amplitude) - 1 : length(amplitude))
    amplitude[interior] .*= 2

    # A periodic Hann window, with power normalization (not amplitude normalization).
    window = [0.5 - 0.5cospi(2i / n) for i in 0:n-1]
    psd = abs2.(rfft(signal .* window)) .* (spacing / sum(abs2, window))
    psd[interior] .*= 2

    # Zero padding gives linear rather than circular correlation. Scaling the centered data
    # first avoids overflowing its squared amplitude; normalization removes that scale again.
    correlation = Float64[]
    scale = maximum(abs, centered)
    if isfinite(scale) && scale > 0
        padded = zeros(nextpow(2, 2n - 1))
        padded[1:n] = centered ./ scale
        correlation = irfft(abs2.(rfft(padded)), length(padded))[1:n]
        correlation ./= first(correlation)
    end
    return VectorSignal(; frequency, amplitude, psd,
        lag=collect(0:n-1) .* spacing, correlation)
end
