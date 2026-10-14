# Parse and transform the user's real project files, read only. Nothing in the project runs:
# only `using` lines and definitions (functions, structs, consts) are evaluated, into sandbox
# modules, once plain and once transformed, to compare definition time and lowered code size.
#
# Run (packages from the user's environment, CodeTrack needs none):
#   julia --startup-file=no --project="<project dir>" transform_project.jl "<project dir>"
include(joinpath(@__DIR__, "src", "CodeTrack.jl")); using .CodeTrack

root = ARGS[1]
isdefstmt(ex) = ex isa Expr && (CodeTrack.isfuncdef(ex) || ex.head in (:struct, :abstract, :primitive, :const, :macro) ||
    (ex.head === :macrocall && ex.args[1] == GlobalRef(Core, Symbol("@doc")) && isdefstmt(ex.args[end])))

# `using X` that cannot load (DataBrowser does not precompile right now) gets an empty stub module.
function load!(sandbox, ex)
    try
        Core.eval(sandbox, ex)
    catch
        for path in (ex.args[1].head === :(:) ? ex.args[1:1] : ex.args)
            p = path.head === :(:) ? path.args[1] : path
            name = p.args[end]
            p.args[1] === :. && continue
            isdefined(sandbox, name) || Core.eval(sandbox, :(module $name end))
            if path.head === :(:)
                for n in path.args[2:end]
                    Core.eval(getglobal(sandbox, name), :(function $(n.args[end]) end))
                    Core.eval(sandbox, :(const $(n.args[end]) = $name.$(n.args[end])))
                end
            end
        end
        stubbed[string(ex)] = true
    end
end
stubbed = Dict{String,Bool}()

stats = Dict(:files => 0, :lines => 0, :statements => 0, :t_parse => 0.0, :t_transform => 0.0,
             :t_def_plain => 0.0, :t_def_tracked => 0.0, :refused => String[], :errors => String[])
function process_file!(file, plain, tracked)
    stats[:files] += 1; stats[:lines] += countlines(file)
    t = @elapsed top = Meta.parseall(read(file, String); filename=file)
    stats[:t_parse] += t
    line = nothing
    for ex in top.args
        ex isa LineNumberNode && (line = ex; continue)
        stats[:statements] += 1
        if ex isa Expr && ex.head in (:using, :import)
            load!(plain, ex); load!(tracked, ex); continue
        end
        if ex isa Expr && ex.head === :call && ex.args[1] === :include && ex.args[2] isa String
            process_file!(joinpath(dirname(file), ex.args[2]), plain, tracked); continue
        end
        local tex
        try
            stats[:t_transform] += @elapsed tex = CodeTrack.transform(tracked, Expr(:block, line, ex))
        catch err
            err isa LoadError && (err = err.error)
            push!(stats[err isa UntrackableCode ? :refused : :errors], "$(relpath(file, root)):$(line.line)  " * first(split(sprint(showerror, err), '\n')))
            continue
        end
        isdefstmt(ex) || continue
        try
            stats[:t_def_plain] += @elapsed Core.eval(plain, ex)
            stats[:t_def_tracked] += @elapsed Core.eval(tracked, tex)
        catch err
            push!(stats[:errors], "$(relpath(file, root)):$(line.line)  definition: " * first(split(sprint(showerror, err), '\n')))
        end
    end
end

lowered_size(mod) = sum((length(Base.uncompressed_ast(m).code) for n in names(mod; all=true)
    if isdefined(mod, n) && getglobal(mod, n) isa Function && parentmodule(getglobal(mod, n)) === mod
    for m in methods(getglobal(mod, n)) if m.module === mod); init=0)
count_calls(mod, f) = sum((count(st -> st == GlobalRef(CodeTrack, f) || (st isa Expr && GlobalRef(CodeTrack, f) in st.args), Base.uncompressed_ast(m).code)
    for n in names(mod; all=true) if isdefined(mod, n) && getglobal(mod, n) isa Function && parentmodule(getglobal(mod, n)) === mod
    for m in methods(getglobal(mod, n)) if m.module === mod); init=0)

function report(title, entry_files)
    for k in keys(stats); stats[k] = stats[k] isa Vector ? String[] : 0 * stats[k]; end
    plain = Module(:Plain); tracked = Module(:Tracked)
    for f in entry_files
        process_file!(f, plain, tracked)
    end
    println("== ", title)
    println("files $(stats[:files]), lines $(stats[:lines]), top-level statements $(stats[:statements])")
    println("parse ", round(stats[:t_parse]*1e3, digits=1), " ms;  macroexpand+transform ", round(stats[:t_transform]*1e3, digits=1), " ms")
    println("define methods: plain ", round(stats[:t_def_plain]*1e3, digits=1), " ms, transformed ", round(stats[:t_def_tracked]*1e3, digits=1), " ms")
    lp, lt = (@invokelatest lowered_size(plain)), (@invokelatest lowered_size(tracked))
    println("lowered statements: plain $lp, transformed $lt (+", round(100*(lt-lp)/max(lp,1)), "%)")
    println("inserted: enter $(@invokelatest count_calls(tracked, :enter)), gread $(@invokelatest count_calls(tracked, :gread)), gread_maybe $(@invokelatest count_calls(tracked, :gread_maybe)) (lowered call sites)")
    isempty(stats[:refused]) || println("refused at load:\n  ", join(stats[:refused], "\n  "))
    isempty(stats[:errors]) || println("other errors:\n  ", join(unique(stats[:errors]), "\n  "))
end

# The first pass compiles the transform and the stubs; only the second pass is printed.
redirect_stdout(devnull) do
    report("warm-up", [joinpath(root, "browser.jl")])
end
report("DataBrowser project (browser.jl and its includes)", [joinpath(root, "browser.jl")])
println("stubbed packages: ", collect(keys(stubbed)))
scripts = filter(f -> endswith(f, ".jl"), readdir(joinpath(root, "scripts"); join=true))
report("standalone scripts (robustness corpus; includes outside the folder skipped)", scripts)
