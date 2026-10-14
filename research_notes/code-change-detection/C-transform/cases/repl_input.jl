myfit(x) = 2x
callbacks = Dict{Symbol,Any}(:process => x -> myfit(x) + 1)
snap = snapshot(run_recorded(() -> callbacks[:process](1.0))[2]); println("fresh: ", changes(snap))
myfit(x) = 3x
println("after REPL redefinition of myfit: ", changes(snap))
snap = snapshot(run_recorded(() -> callbacks[:process](1.0))[2])
callbacks[:process] = x -> myfit(x) - 1
println("after re-registering the callback: ", changes(snap), "  <- read of the non-const global `callbacks`")
