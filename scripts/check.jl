# Package isolation and resolution belong to Pkg. This runner only chooses workloads.
using Pkg, SHA, TOML, Dates
include(joinpath(@__DIR__, "..", "bench", "run.jl"))
include(joinpath(@__DIR__, "..", "bench", "report.jl"))

const ROOT = dirname(@__DIR__)
const BENCH = joinpath(ROOT, "bench")
const RESULTS = joinpath(BENCH, "results")
const PACKAGES = sort(["DataBrowser" * name for name in
    ("API", "Annotations", "Cache", "Core", "GUI", "Plots", "Profiling", "Recipes", "Sources")])
const RECORD_FILE = joinpath(RESULTS, "checks.toml")

function hash_files(io, path)
    ispath(path) || return
    files = isfile(path) ? [path] : sort([joinpath(dir, file)
        for (dir, _, names) in walkdir(path) for file in names])
    for file in files
        println(io, relpath(file, ROOT))
        write(io, read(file))
    end
end

"""Fingerprint resolved dependencies and local source contents, including uncommitted edits."""
function fingerprint(names, command; tests=false, workload=nothing)
    dependencies = Pkg.dependencies()
    byname = Dict(info.name => uuid for (uuid, info) in dependencies)
    visited = Set()
    io = IOBuffer()
    println(io, VERSION, Sys.MACHINE, Sys.CPU_NAME, Threads.nthreads())
    println(io, command.exec)
    hash_files(io, joinpath(BENCH, "LocalPreferences.toml"))
    hash_files(io, joinpath(ROOT, "LocalPreferences.toml"))
    function visit(uuid)
        uuid in visited && return
        push!(visited, uuid)
        info = dependencies[uuid]
        println(io, uuid, info.version, info.tree_hash)
        if info.is_tracking_path
            for name in ("Project.toml", "src", "ext", "deps", "assets", "LocalPreferences.toml")
                hash_files(io, joinpath(info.source, name))
            end
            info.name == "DataBrowser" && hash_files(io, joinpath(info.source, "test", "fixtures", "TASE"))
        end
        for dependency in sort(collect(values(info.dependencies)); by=string)
            visit(dependency)
        end
        project_file = joinpath(info.source, "Project.toml")
        if isfile(project_file)
            project = TOML.parsefile(project_file)
            extensions = get(project, "extensions", Dict())
            for extension in sort(collect(keys(extensions)))
                trigger = extensions[extension]
                triggers = trigger isa String ? [trigger] : trigger
                all(name -> haskey(byname, name), triggers) || continue
                for name in sort(triggers)
                    visit(byname[name])
                end
            end
        end
    end
    for name in sort(names)
        visit(byname[name])
        if tests
            source = dependencies[byname[name]].source
            hash_files(io, joinpath(source, "test"))
            project = TOML.parsefile(joinpath(source, "Project.toml"))
            for dependency in sort(get(get(project, "targets", Dict()), "test", String[]))
                visit(byname[dependency])
            end
        end
    end
    if workload !== nothing
        for file in workload
            hash_files(io, joinpath(ROOT, file))
        end
        println(io, get(ENV, "MB_BENCH_REPEATS", "3"))
    end
    return bytes2hex(sha256(take!(io)))
end

"""Run one command only when its inputs differ from the last successful run."""
function checked(f, records, name, key; force=false)
    if !force && get(get(records, name, Dict()), "inputs", nothing) == key
        println(name, ": unchanged (previous success reused)")
        return records[name]
    end
    println(name, ": running")
    result = try
        f()
    catch
        delete!(records, name)
        mkpath(RESULTS)
        open(io -> TOML.print(io, records; sorted=true), RECORD_FILE, "w")
        rethrow()
    end
    record = Dict{String,Any}("inputs" => key, "measured_at" => string(Dates.now()))
    result === nothing || merge!(record, result)
    records[name] = record
    mkpath(RESULTS)
    open(io -> TOML.print(io, records; sorted=true), RECORD_FILE, "w")
    return record
end

"""An isolated compiled cache, sharing installed package sources and binary artifacts."""
function measurement_depot()
    depot = joinpath(RESULTS, "depot")
    mkpath(depot)
    for name in ("packages", "artifacts", "registries")
        target = joinpath(depot, name)
        if !ispath(target)
            source = findfirst(d -> isdir(joinpath(d, name)), DEPOT_PATH)
            source === nothing || symlink(joinpath(DEPOT_PATH[source], name), target)
        end
    end
    return depot
end

function julia_command(arguments; depot)
    command = `$(Base.julia_cmd()) --startup-file=no --project=$BENCH --threads=$(Threads.nthreads()) $arguments`
    return addenv(command, "JULIA_DEPOT_PATH" => depot * string(Sys.iswindows() ? ';' : ':'))
end

"""Run selected package tests; the full selection also runs clean compilation and smoke benchmarks."""
function check(args=ARGS)
    force = "--force" in args
    selected = filter(!=("--force"), args)
    full = isempty(selected)
    package = full ? nothing : startswith(first(selected), "DataBrowser") ? first(selected) : "DataBrowser" * first(selected)
    benchmark = !full && first(selected) == "bench"
    precompile_only = !full && first(selected) == "precompile"
    full || benchmark || precompile_only || package in PACKAGES || error("Unknown package: $(first(selected))")
    records = isfile(RECORD_FILE) ? TOML.parsefile(RECORD_FILE) : Dict{String,Any}()
    depot = measurement_depot()
    if full || precompile_only
        names = collect(keys(Pkg.project().dependencies))
        # Named selection can omit extensions whose triggers include other extensions.
        # Prepare the environment, then require its plotting stack without another cache build.
        prepare = """
            using Pkg
            Pkg.precompile(; strict=true)
            using DataBrowser, DataBrowserPlots, GLMakie, AlgebraOfGraphics
            for extension in (:DataBrowserPlotsGUIExt, :DataBrowserPlotsAlgebraOfGraphicsExt)
                Base.get_extension(DataBrowserPlots, extension) === nothing && error("Extension failed to load: \$extension")
            end
            """
        command = julia_command(["--compiled-modules=strict", "-e", prepare]; depot)
        code = fingerprint(names, command)
        checked(records, "precompile", code; force=force && precompile_only) do
            # Remove the compiled code of the DataBrowser packages only, in this runner-owned
            # depot. A dependency keeps its compiled code, which Julia rebuilds by itself when
            # the version of the dependency changes.
            compiled = joinpath(depot, "compiled", "v$(VERSION.major).$(VERSION.minor)")
            for name in (isdir(compiled) ? readdir(compiled) : String[])
                startswith(name, "DataBrowser") && rm(joinpath(compiled, name); recursive=true)
            end
            seconds = @elapsed run(command)
            fingerprint(names, command) == code || error("Package code changed during precompilation")
            # Startup measurements must use the newly completed compiled cache.
            delete!(records, "engine")
            delete!(records, "browser")
            Dict("seconds" => seconds)
        end
    end
    if full || (!benchmark && !precompile_only)
        for name in (full ? PACKAGES : [package])
            # A package without tests is checked by precompilation only.
            isdir(joinpath(ROOT, "lib", name, "test")) || continue
            files = full ? String[] : selected[2:end]
            # A selected file is an explicit diagnostic run, not a pass for the whole package.
            test_code = "using Pkg; Pkg.test($(repr(name)); allow_reresolve=false, julia_args=[\"--check-bounds=auto\"], test_args=$(repr(files)))"
            command = julia_command(["-e", test_code]; depot)
            key = fingerprint([name], command; tests=true)
            if isempty(files)
                checked(records, name, key; force) do
                    run(command)
                    fingerprint([name], command; tests=true) == key || error("$name changed while its tests ran")
                    nothing
                end
            else
                run(command)
            end
        end
    end
    if full || benchmark
        workloads = full || length(selected) == 1 ? ["engine", "browser"] : selected[2:end]
        for workload in workloads
            workload in ("engine", "browser") || error("Unknown benchmark: $workload")
            files = workload == "engine" ? ["bench/run.jl", "bench/worker.jl", "bench/workloads.jl"] :
                ["bench/run.jl", "bench/worker.jl", "bench/browser.jl", "bench/smoke_project.jl", "test/fixtures/public_api", "test/fixtures/public_api_variants"]
            command = julia_command(String[]; depot)
            key = fingerprint(["DataBrowser"], command; workload=files)
            record = checked(records, workload, key; force) do
                result = measure_benchmark(workload, command)
                fingerprint(["DataBrowser"], command; workload=files) == key || error("Benchmark inputs changed during the run")
                Dict("result" => result)
            end
            TOML.print(stdout, record["result"]; sorted=true)
        end
        full && write_report(records)
    end
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    check()
end
