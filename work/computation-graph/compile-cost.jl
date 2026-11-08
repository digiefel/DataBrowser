# Where does the first-use time of a new kind go, and does it depend on how Core holds values?
# Run: julia --startup-file=no work/computation-graph/compile-cost.jl
abstract type Item end
rc(x) = x.Rc
# Warm every function on one kind, so later timings show only what a new kind adds.
struct Warm <: Item; Rc::Float64; Chip::String; end
let xs = [Warm(1.0, "A"), Warm(2.0, "B")], ys = Item[xs...]
    string(xs[1]); sort(xs; by = rc); sort(ys; by = rc); sum(rc, ys); sum(rc, xs)
end
for i in 1:2
    T = Symbol("Fit$i")
    t = @elapsed Core.eval(Main, :(struct $T <: Item; Rc::Float64; Chip::String; end))
    K = Base.invokelatest(getfield, Main, T)
    c = @elapsed (xs = Base.invokelatest(() -> [K(1.0, "A"), K(2.0, "B")]))
    ys = Item[xs...]
    step(f) = round(1000 * @elapsed(Base.invokelatest(f)); digits = 2)
    println("kind $i: define ", round(1000t; digits = 2), " ms, construct ", round(1000c; digits = 2), " ms")
    println("  held as Vector{Item} (abstract): sort ", step(() -> sort(ys; by = rc)), " ms, sum ", step(() -> sum(rc, ys)), " ms")
    println("  held as Vector{Fit} (concrete):  sort ", step(() -> sort(xs; by = rc)), " ms, sum ", step(() -> sum(rc, xs)), " ms")
    println("  show one value:                  ", step(() -> string(xs[1])), " ms")
end
