using Test
using Grafico: StatsBase

@testset "Time before a reduction and time after a reduction" begin
    rows = [(id = Symbol("sample_", i), order = i, group = i <= 6 ? :low : :high,
             value = Float64(i), weight = 1.0) for i in 1:10]
    plan = transfer_plan(rows; id = r -> r.id, group = r -> r.group,
                         value = r -> r.value, order = r -> r.order)
    @test sample_transfer(plan, 0).counts == [0, 0]
    @test sample_transfer(plan, 1).counts == [6, 4]
    @test sample_output_exposure(plan, 0.5) == [6, 0]
    @test sample_transfer(plan, 0.5).counts != sample_output_exposure(plan, 0.5)

    for p in range(0, 1; length = 101)
        frame = sample_transfer(plan, p)
        @test sum(frame.counts) == count(frame.arrived)
        @test sum(frame.mass) == count(frame.arrived)
        @test all(0 .<= frame.local_progress .<= 1)
        @test frame.arrived == (frame.local_progress .== 1)
    end
    @test isequal(sample_transfer(plan, -1), sample_transfer(plan, 0))
    @test isequal(sample_transfer(plan, 2), sample_transfer(plan, 1))
    @test_throws ArgumentError sample_transfer(plan, NaN)
end

@testset "Arbitrary group keys, weighted count, sum, and mean" begin
    rows = [
        (id = :a, order = 2, group = (:sensor, 1), value = 4.0, weight = 2.0),
        (id = :b, order = 1, group = (:sensor, 2), value = -2.0, weight = 1.5),
        (id = :c, order = 2, group = (:sensor, 1), value = 10.0, weight = 0.5),
        (id = :d, order = 3, group = (:sensor, 2), value = 6.0, weight = 0.0),
    ]
    options = (id = r -> r.id, group = r -> r.group, value = r -> r.value,
               weight = r -> r.weight, order = r -> r.order)
    plan = transfer_plan(rows; options...)
    frame = sample_transfer(plan, 1)
    for (j, key) in enumerate(plan.groups)
        group_rows = filter(r -> r.group == key, rows)
        @test frame.counts[j] == length(group_rows)
        @test frame.mass[j] ≈ sum(r.weight for r in group_rows)
        @test frame.weighted_sum[j] ≈ sum(r.weight * r.value for r in group_rows)
        @test frame.means[j] ≈ sum(r.weight * r.value for r in group_rows) / sum(r.weight for r in group_rows)
    end

    # Different input storage and repeated order values retain all correspondences.
    permuted = transfer_plan(rows[[4, 2, 1, 3]]; options...)
    @test plan.contributions == permuted.contributions
    @test plan.groups == permuted.groups
    @test plan.slots == permuted.slots
    for p in (0.8, 0.2, 1.0, 0.5, 0.0, 0.2)
        @test isequal(sample_transfer(plan, p), sample_transfer(permuted, p))
    end
    @test isequal(sample_transfer(plan, 0.2), sample_transfer(plan, 0.2))
    @test sum(frame.mass) ≈ 4
    @test sum(frame.weighted_sum) ≈ 10
end

@testset "Observation, view instance, and pair identities" begin
    rows = [(id = id, order = i, group = :all, value = 10.0i) for (i, id) in enumerate((:a, :b, :c, :d))]
    opts = (id = r -> r.id, group = r -> r.group, value = r -> r.value, order = r -> r.order)
    plan = transfer_plan(rows; opts...)
    @test last.(mark_keys(plan, :raw)) == last.(mark_keys(plan, :inset))
    @test isempty(intersect(mark_keys(plan, :raw), mark_keys(plan, :inset)))
    pairs = paired_observations(plan, 1)
    @test getproperty.(pairs, :id) == [(:a, :b), (:b, :c), (:c, :d)]
    @test paired_observations(transfer_plan(reverse(rows); opts...), 1) == pairs
    @test [(p.x, p.y) for p in pairs] == [(10.0, 20.0), (20.0, 30.0), (30.0, 40.0)]
    @test flight_position((1, 2), (7, 8), 0) == (1, 2)
    @test flight_position((1, 2), (7, 8), 1) == (7, 8)
    @test flight_position((1, 2), (7, 8), 0.5) != (4, 5)
    @test_throws ArgumentError paired_observations(plan, 0)
end

@testset "Fixed-bin membership boundaries" begin
    edges = [0.0, 1.0, 2.0, 3.0]
    left = StatsBase.Histogram((edges,), :left)
    right = StatsBase.Histogram((edges,), :right)
    @test StatsBase.binindex(left, 0) == 1
    @test StatsBase.binindex(left, 1) == 2
    @test StatsBase.binindex(left, 3) == 4 # Outside the left-closed support.
    @test StatsBase.binindex(right, 3) == 3
    @test_throws ArgumentError transfer_plan([(id = 1, value = 1), (id = 1, value = 2)];
        id = r -> r.id, value = r -> r.value, group = _ -> :all, order = r -> r.value)
end
