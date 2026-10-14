# Mechanism 2, limits: constructs where the overlay pass may lose track, and the compile cost
# of running a package-heavy stage (CSV.read + DataFrames sort) under the pass.
# Run (uses the examples environment for CSV/DataFrames, this folder for CassetteOverlay):
#   JULIA_LOAD_PATH="@:$PWD:@stdlib" julia --startup-file=no --project=../../../examples 05_overlay_edge_cases.jl
using CassetteOverlay, CSV, DataFrames

module User
leaf_spawn(x) = x + 1
leaf_latest(x) = x + 2
leaf_catch(x) = x + 3
leaf_eval(x) = x + 4
leaf_cfunction(x::Cdouble)::Cdouble = x + 5
spawned(x) = fetch(Threads.@spawn leaf_spawn(x))
latest(x) = Base.invokelatest(leaf_latest, x)
caught(x) = try error("x") catch; leaf_catch(x) end
evaled(x) = Core.eval(User, :(leaf_eval($x)))
viac(x) = (f = @cfunction(leaf_cfunction, Cdouble, (Cdouble,)); ccall(f, Cdouble, (Cdouble,), x))
clean(path) = sort!(Main.CSV.read(path, Main.DataFrame), :voltage_v)
end

@MethodTable EmptyTable
const PASSES = Any[]
# A fresh pass type per experiment, so each one starts with an empty set of compiled signatures.
function newpass()
    name = Symbol(:Pass, length(PASSES))
    @eval struct $name <: CassetteOverlay.OverlayPass end
    @eval @overlaypass $name EmptyTable
    T = getfield(Main, name); push!(PASSES, T); return T
end
function executed(P)
    passmethod = only(m for m in methods(P()) if m.nargs == 2 && m.isva)
    found = Set{Method}()
    for mi in Base.specializations(passmethod)
        ftypes = mi.specTypes.parameters[2:end]
        isempty(ftypes) && continue
        all(t -> t isa Type && Base.isdispatchtuple(Tuple{t}), ftypes) || continue
        m = try which(Tuple{ftypes...}) catch; nothing end
        m isa Method && push!(found, m)
    end
    return found
end

for (f, leaf) in ((User.spawned, :leaf_spawn), (User.latest, :leaf_latest), (User.caught, :leaf_catch),
                  (User.evaled, :leaf_eval), (User.viac, :leaf_cfunction))
    P = newpass()
    r = try invokelatest(invokelatest(P), f, 1.0) catch e; sprint(showerror, e)[1:min(end, 80)] end
    seen = any(m -> m.name === leaf, invokelatest(executed, P))
    println(rpad(string(nameof(f)), 9), " result ", rpad(string(r), 6), " leaf recorded: ", seen)
end

path = tempname() * ".csv"
CSV.write(path, DataFrame(voltage_v = rand(10_000), current_a = rand(10_000)))
t_native_first = @elapsed User.clean(path)
t_native = minimum(@elapsed(User.clean(path)) for _ in 1:20)
P = newpass(); p = invokelatest(P)
t_pass_first = @elapsed invokelatest(p, User.clean, path)
t_pass = minimum(@elapsed(invokelatest(p, User.clean, path)) for _ in 1:20)
println("CSV.read + sort!: native first $(round(t_native_first; digits = 2)) s, then $(round(t_native * 1e3; digits = 2)) ms; ",
        "overlay first $(round(t_pass_first; digits = 2)) s, then $(round(t_pass * 1e3; digits = 2)) ms; ",
        "methods recorded: $(length(invokelatest(executed, P)))")
