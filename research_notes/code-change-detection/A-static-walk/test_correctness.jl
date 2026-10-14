# Correctness checks for `code_revision`.
# Run: julia --startup-file=no --project=bench research_notes/code-change-detection/A-static-walk/test_correctness.jl
# (needs Revise and DataBrowser; the `bench` environment has both)

using Revise
using DataBrowser
include(joinpath(@__DIR__, "CodeRevision.jl"))
using .CodeRevision

results = Pair{String,Bool}[]
check(name, ok) = (push!(results, name => ok); println(ok ? "PASS " : "FAIL ", name))
rev(x) = code_revision(x isa Vector ? x : [x]; exclude=LIBRARY_MODULES).hash

# --- 1. Nested helper redefinition affects only the dependent stage ---------------------------
Core.eval(Main, quote
    inner(x) = x + 1
    middle(x) = inner(x) * 2
    stage_a(x) = middle(x)
    stage_b(x) = x - 1
    unrelated(x) = 0
end)
a0, b0 = rev(stage_a), rev(stage_b)
Core.eval(Main, :(inner(x) = x + 2))
check("nested helper change -> dependent stage hash changes", rev(stage_a) != a0)
check("nested helper change -> independent stage unchanged", rev(stage_b) == b0)
a1 = rev(stage_a)
Core.eval(Main, :(unrelated(x) = 1))
check("unrelated function change -> no hash changes", rev(stage_a) == a1 && rev(stage_b) == b0)
Core.eval(Main, :(inner(x) = x + 1))
check("reverting the edit restores the original hash", rev(stage_a) == a0)

# --- 2. Closures, keyword functions, functions passed by name, new methods ------------------
Core.eval(Main, quote
    fit(x) = 2x
    by_closure(xs) = map(y -> fit(y) + 1, xs)
    by_name(xs) = map(fit, xs)
    kwhelper(x; scale=1) = fit(x) * scale
    by_kw(x) = kwhelper(x; scale=3)
end)
c0, n0, k0 = rev(by_closure), rev(by_name), rev(by_kw)
Core.eval(Main, :(fit(x) = 3x))
check("closure body sees helper change", rev(by_closure) != c0)
check("function passed by name sees change", rev(by_name) != n0)
check("keyword-function body sees change", rev(by_kw) != k0)
n1 = rev(by_name)
Core.eval(Main, :(fit(x::String) = x))
check("new method on a reached generic function changes hash", rev(by_name) != n1)

# --- 3. Const globals and types ---------------------------------------------------------------
Core.eval(Main, quote
    const SCALE = 2.0
    struct Point; x::Float64; end
    scaled(p::Point) = Point(p.x * SCALE)
end)
s0 = rev(scaled)
Core.eval(Main, :(const SCALE = 3.0))
check("const value redefinition changes hash", rev(scaled) != s0)
s1 = rev(scaled)
Core.eval(Main, :(struct Point; x::Float64; y::Float64; end))
# Old `scaled` still refers to the old Point; Revise or the user re-evaluates the method.
Core.eval(Main, :(scaled(p::Point) = Point(p.x * SCALE, p.y)))
check("struct redefinition (1.12+) changes hash", rev(scaled) != s1)

# --- 4. Session stability: the same source gives the same hash in a fresh process ------------
src = """
include($(repr(joinpath(@__DIR__, "CodeRevision.jl")))); using .CodeRevision
helper(x) = x + 1
other_closure = z -> z            # shifts gensym counters
stage(xs; k=2) = map(y -> helper(y) * k, xs)
print(code_revision([stage]).hash)
"""
src2 = replace(src, "other_closure = z -> z            # shifts gensym counters\n" => "")
h1 = read(`$(Base.julia_cmd()) --startup-file=no -e $src`, String)
h2 = read(`$(Base.julia_cmd()) --startup-file=no -e $src2`, String)
check("hash stable across sessions and gensym counters ($(h1[1:8]) vs $(h2[1:8]))", h1 == h2)

# --- 5. Revise-driven file edit -----------------------------------------------------------------
dir = mktempdir(@__DIR__)
file = joinpath(dir, "TrackedHelpers.jl")
write(file, """
module TrackedHelpers
helper(x) = x + 1
work(x) = helper(x) * 10
other(x) = x
end
""")
includet(file)
w0, o0 = rev(TrackedHelpers.work), rev(TrackedHelpers.other)
sleep(1.1)  # file mtime resolution
write(file, replace(read(file, String), "helper(x) = x + 1" => "helper(x) = x + 5"))
sleep(0.5); Revise.revise()
check("Revise file edit -> dependent hash changes", rev(TrackedHelpers.work) != w0)
check("Revise file edit -> independent hash unchanged", rev(TrackedHelpers.other) == o0)
w1 = rev(TrackedHelpers.work)
sleep(1.1)
write(file, replace(read(file, String), "helper(x) = x + 5" => "# a comment\n\nhelper(x) = x + 5"))
sleep(0.5); Revise.revise()
check("Revise: comment/line shift only -> hash unchanged", rev(TrackedHelpers.work) == w1)
rm(dir; recursive=true)

# --- 6. Recipes: register_item! replacing a callback --------------------------------------------
Core.eval(Main, :(clean(data, md) = data .+ 1))
project = define_project("t")
register_item!(project, :k; read = f -> (data=[1.0], metadata=Dict()), process = clean,
    analyze = (data, md) -> Dict(:n => length(data)))
recipe_roots(p, kind) = (r = only(filter(r -> r.kind === kind, p.recipes)); [r.process])
analyze_roots(p, kind) = (r = only(filter(r -> r.kind === kind, p.recipes)); [r.analyze])
p0, an0 = rev(recipe_roots(project, :k)), rev(analyze_roots(project, :k))
register_item!(project, :k; read = f -> (data=[1.0], metadata=Dict()),
    process = (data, md) -> clean(data, md) .* 2,
    analyze = (data, md) -> Dict(:n => length(data)))
check("register_item! with a new process callback -> process hash changes",
    rev(recipe_roots(project, :k)) != p0)
check("register_item! re-run with identical analyze text -> analyze hash unchanged",
    rev(analyze_roots(project, :k)) == an0)

# Closure capturing data: same code, different captured value.
make_cb(s) = (d, m) -> d .* s
check("closure capture value is part of the hash", rev(make_cb(2)) != rev(make_cb(3)))

println("\n", count(last, results), "/", length(results), " passed")
