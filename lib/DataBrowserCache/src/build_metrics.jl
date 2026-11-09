"""
The total time and the number of the writes of item records and of metadata to the cache, counted
since the last [`reset_build_metrics!`](@ref). Counting costs little, so it is always on.
"""
mutable struct BuildMetrics
    item_write_ns::Base.Threads.Atomic{Int64}
    item_writes::Base.Threads.Atomic{Int64}
    metadata_write_ns::Base.Threads.Atomic{Int64}
    metadata_writes::Base.Threads.Atomic{Int64}
end

"""Build metrics with every counter at zero."""
function BuildMetrics()::BuildMetrics
    counter() = Base.Threads.Atomic{Int64}(0)
    return BuildMetrics(counter(), counter(), counter(), counter())
end

"""Set every counter of `metrics` to zero, as the workspace does when a scan of the source starts."""
function reset_build_metrics!(metrics::BuildMetrics)::Nothing
    for counter in (
        metrics.item_write_ns,
        metrics.item_writes,
        metrics.metadata_write_ns,
        metrics.metadata_writes,
    )
        counter[] = 0
    end
    return nothing
end

"""Add the time since `t0_ns` to `total_ns`, and one write to `calls`."""
@inline function record_cache_phase!(
    total_ns::Base.Threads.Atomic{Int64},
    calls::Base.Threads.Atomic{Int64},
    t0_ns::UInt64,
)::Nothing
    Base.Threads.atomic_add!(total_ns, Int64(time_ns() - t0_ns))
    Base.Threads.atomic_add!(calls, Int64(1))
    return nothing
end
