# How often does `Base.get_world_counter()` move during ordinary REPL work?
# Run: julia --startup-file=no --project=bench research_notes/code-change-detection/A-static-walk/world_counter.jl
# Each step is evaluated at top level, as a REPL entry would be.

using Revise

steps = [
    "evaluate an expression" => :(1 + 1),
    "call an existing function first time (compiles)" => :(sum(rand(3))),
    "new non-const global x = 1" => :(x = 1),
    "reassign x = 2" => :(x = 2),
    "reassign x = \"text\" (other type)" => :(x = "text"),
    "new const global" => :(const C1 = 1),
    "redefine const with a new value" => :(const C1 = 2),
    "mutate a const Dict" => :(const D = Dict(1 => 2); nothing),
    "  push! into that const Dict" => :(D[3] = 4),
    "define a new function" => :(f(x) = x + 1),
    "redefine it with the same body" => :(f(x) = x + 1),
    "redefine it with a new body" => :(f(x) = x + 2),
    "add a method" => :(f(x::String) = x),
    "define an anonymous function" => :(g = y -> y),
    "define a struct" => :(struct S; a::Int; end),
    "redefine the struct identically" => :(struct S; a::Int; end),
    "redefine the struct with a new field" => :(struct S; a::Int; b::Int; end),
    "using an already loaded package" => :(using Revise),
    "using a stdlib not yet loaded (Printf)" => :(using Printf),
    "using a heavier package (DataFrames)" => :(using DataFrames),
    "Revise.revise() with no changes" => :(Revise.revise()),
]

println(rpad("step", 52), "world delta")
for (label, ex) in steps
    before = Base.get_world_counter()
    Core.eval(Main, ex)
    println(rpad(label, 52), Int(Base.get_world_counter() - before))
end
