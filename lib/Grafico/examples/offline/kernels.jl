module GraficoPortableKernels

"""Rotate a point after stretching its horizontal coordinate."""
cloud_x(angle::Float64, stretch::Float64, x::Float64, y::Float64) =
    cos(angle) * stretch * x - sin(angle) * y

cloud_y(angle::Float64, stretch::Float64, x::Float64, y::Float64) =
    sin(angle) * stretch * x + cos(angle) * y

"""An author-supplied closed trajectory, evaluated from its captured start."""
swing(start::Float64, progress::Float64) = start + 0.25 * sinpi(8 * progress)

"""Integrate the piecewise-linear measured trace over an arbitrary interval."""
function interval_integral(time::Vector{Float64}, signal::Vector{Float64},
                           lower::Float64, upper::Float64)
    area = 0.0
    for i in 1:length(time)-1
        left = max(lower, time[i])
        right = min(upper, time[i + 1])
        if right > left
            span = time[i + 1] - time[i]
            slope = (signal[i + 1] - signal[i]) / span
            yleft = signal[i] + (left - time[i]) * slope
            yright = signal[i] + (right - time[i]) * slope
            area += (yleft + yright) * (right - left) / 2
        end
    end
    area
end

end
