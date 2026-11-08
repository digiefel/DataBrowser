# Probe: find an anonymous function again in a later session by its code, not by its generated name.
# Session 1 records the hash of the function's lowered code; session 2 loads a changed script, where
# the generated names have shifted, and looks the function up by that hash.
# Run: julia --startup-file=no work/computation-graph/anonymous-by-content.jl
script1 = """
current(x) = x.I
f = x -> x.I .* 1000
"""
script2 = """
other = y -> y + 1             # a new function earlier in the script shifts the generated names
current(x) = x.I
f = x -> x.I .* 1000
"""
lookup = raw"""
# The function's identity: its lowered code, without line numbers and generated names.
content(f) = hash(string(Base.remove_linenums!(only(code_lowered(f)))))
# Every closure type of a module, by the content of its code.
function closures(m::Module)
    found = Dict{UInt,Any}()
    for name in names(m; all = true)
        startswith(string(name), "#") || continue
        T = getglobal(m, name)
        T isa DataType && T <: Function && isdefined(T, :instance) && (found[content(T.instance)] = T.instance)
    end
    return found
end
"""
for (session, script) in (("session 1", script1), ("session 2", script2))
    code = lookup * script * """
        println("$session: generated name ", nameof(typeof(f)), ", content ", repr(content(f)))
        """ * (session == "session 2" ? """
        println("  the function stored in session 1 is found again: ", get(closures(Main), parse(UInt, ENV["CONTENT"]), nothing) === f)
        """ : "")
    out = read(addenv(`$(Base.julia_cmd()) --startup-file=no -e $code`, "CONTENT" => get(ENV, "CONTENT", "0")), String)
    print(out)
    session == "session 1" && (ENV["CONTENT"] = string(parse(UInt, last(split(strip(out))))))
end

# Scope: lowered code names globals with their module, so two modules give two hashes. Two
# closures from different enclosing functions share a hash and differ only in captured values.
include_string(Main, lookup)
module A; helper(x) = 2x; f = x -> helper(x); end
module B; helper(x) = 3x; f = x -> helper(x); end
outer1() = (a = 1; x -> x + a)
outer2() = (a = 2; x -> x + a)
println("same code in two modules, same hash: ", content(A.f) == content(B.f))
println("same code in two enclosing functions, same hash: ", content(outer1()) == content(outer2()),
    "; results ", outer1()(1), " and ", outer2()(1))
