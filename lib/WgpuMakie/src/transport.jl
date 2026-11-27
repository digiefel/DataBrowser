# Subprocess Unix-socket transport between Julia and `wgpu-makie-viewer`.

function find_viewer_binary()
    env_bin = get(ENV, "WGPU_MAKIE_VIEWER", "")
    if !isempty(env_bin) && isfile(env_bin)
        return env_bin
    end
    crate_root = joinpath(@__DIR__, "..", "crates", "target")
    for profile in ("release", "debug")
        cand = joinpath(crate_root, profile, "wgpu-makie-viewer")
        isfile(cand) && return cand
    end
    error(
        "Could not find `wgpu-makie-viewer` binary under $crate_root. " *
        "Build it with `cargo build --release --bin wgpu-makie-viewer` in `lib/WgpuMakie/crates`."
    )
end

mutable struct ViewerProcess
    socket_path::String
    server::Sockets.PipeServer
    conn::Union{Nothing, Sockets.PipeEndpoint}
    proc::Base.Process
    write_lock::ReentrantLock
    req_lock::ReentrantLock
    pending_colorbuffer::Dict{UInt64, Channel{Any}}
    pending_pick::Dict{UInt64, Channel{Any}}
    next_req_id::Threads.Atomic{UInt64}
    ready::Channel{Any}
    reader_task::Union{Nothing, Task}
    open::Threads.Atomic{Bool}
    on_event::Function
end

const _SOCKET_COUNTER = Threads.Atomic{UInt64}(0)

function start_viewer!(on_event::Function; headless::Bool = false)
    bin = find_viewer_binary()
    seq = Threads.atomic_add!(_SOCKET_COUNTER, UInt64(1))
    socket_path = joinpath(
        "/tmp",
        "wm-$(getpid())-$(seq).sock",
    )
    ispath(socket_path) && rm(socket_path; force = true)
    server = Sockets.listen(socket_path)

    args = String["--socket", socket_path]
    headless && push!(args, "--headless")
    cmd = Cmd(`$bin $args`; detach = false)
    proc = open(cmd, "r") # stderr goes to terminal; stdout unused

    # Accept connection with bounded wait
    accept_ch = Channel{Any}(1)
    @async try
        put!(accept_ch, Sockets.accept(server))
    catch e
        put!(accept_ch, e)
    end
    t0 = time()
    while !isready(accept_ch) && (time() - t0) < 15.0
        if !process_running(proc)
            close(server)
            ispath(socket_path) && rm(socket_path; force = true)
            error("wgpu-makie-viewer exited prematurely (exit code $(proc.exitcode))")
        end
        sleep(0.002)
    end
    if !isready(accept_ch)
        close(server)
        kill(proc)
        ispath(socket_path) && rm(socket_path; force = true)
        error("Timed out waiting for wgpu-makie-viewer to connect on $socket_path")
    end
    conn = take!(accept_ch)
    conn isa Exception && throw(conn)

    vp = ViewerProcess(
        socket_path,
        server,
        conn,
        proc,
        ReentrantLock(),
        ReentrantLock(),
        Dict{UInt64, Channel{Any}}(),
        Dict{UInt64, Channel{Any}}(),
        Threads.Atomic{UInt64}(1),
        Channel{Any}(1),
        nothing,
        Threads.Atomic{Bool}(true),
        on_event,
    )

    vp.reader_task = @async _viewer_reader_loop!(vp)

    t1 = time()
    while !isready(vp.ready) && (time() - t1) < 15.0
        if !vp.open[]
            error("wgpu-makie-viewer disconnected before sending Ready")
        end
        sleep(0.002)
    end
    if !isready(vp.ready)
        close_viewer!(vp)
        error("Timed out waiting for Ready message from wgpu-makie-viewer")
    end
    take!(vp.ready)
    return vp
end

function _viewer_reader_loop!(vp::ViewerProcess)
    try
        while vp.open[] && !isnothing(vp.conn) && isopen(vp.conn)
            msg = read_frame(vp.conn)
            isnothing(msg) && break
            op = get(msg, "op", "")
            if op == "ready"
                isready(vp.ready) || put!(vp.ready, msg)
            elseif op == "color_buffer_reply"
                rid = UInt64(msg["request_id"])
                ch = @lock vp.req_lock pop!(vp.pending_colorbuffer, rid, nothing)
                !isnothing(ch) && put!(ch, msg)
            elseif op == "pick_reply"
                rid = UInt64(msg["request_id"])
                ch = @lock vp.req_lock pop!(vp.pending_pick, rid, nothing)
                !isnothing(ch) && put!(ch, msg)
            else
                try
                    vp.on_event(msg)
                catch e
                    @warn "Error handling viewer event $op" exception = (e, catch_backtrace())
                end
            end
        end
    catch e
        if vp.open[] && !(e isa EOFError)
            @warn "Viewer socket reader stopped" exception = (e, catch_backtrace())
        end
    finally
        vp.open[] = false
        @lock vp.req_lock begin
            for ch in values(vp.pending_colorbuffer)
                isready(ch) || put!(ch, ErrorException("Viewer disconnected"))
            end
            empty!(vp.pending_colorbuffer)
            for ch in values(vp.pending_pick)
                isready(ch) || put!(ch, ErrorException("Viewer disconnected"))
            end
            empty!(vp.pending_pick)
        end
        try
            vp.on_event(Dict{String, Any}("op" => "window_closed"))
        catch
        end
    end
    return nothing
end

function send_msg!(vp::ViewerProcess, msg)
    vp.open[] || return nothing
    conn = vp.conn
    (isnothing(conn) || !isopen(conn)) && return nothing
    @lock vp.write_lock begin
        write_frame(conn, msg)
    end
    return nothing
end

function request_colorbuffer(vp::ViewerProcess, width::Integer, height::Integer, px_per_unit::Real)
    vp.open[] || error("Viewer is closed")
    rid = Threads.atomic_add!(vp.next_req_id, UInt64(1))
    ch = Channel{Any}(1)
    @lock vp.req_lock begin
        vp.pending_colorbuffer[rid] = ch
    end
    send_msg!(vp, Dict{String, Any}(
        "op" => "request_color_buffer",
        "request_id" => rid,
        "width" => UInt32(max(1, Int(width))),
        "height" => UInt32(max(1, Int(height))),
        "px_per_unit" => Float32(px_per_unit),
    ))
    t0 = time()
    while !isready(ch) && (time() - t0) < 30.0
        vp.open[] || error("Viewer closed while waiting for colorbuffer")
        sleep(0.002)
    end
    if !isready(ch)
        @lock vp.req_lock pop!(vp.pending_colorbuffer, rid, nothing)
        error("Timed out waiting for colorbuffer reply from viewer")
    end
    res = take!(ch)
    res isa Exception && throw(res)
    return res
end

function request_pick(vp::ViewerProcess, x::Integer, y::Integer, range::Integer, sorted::Bool)
    vp.open[] || return Tuple{UInt64, UInt32}[]
    rid = Threads.atomic_add!(vp.next_req_id, UInt64(1))
    ch = Channel{Any}(1)
    @lock vp.req_lock begin
        vp.pending_pick[rid] = ch
    end
    send_msg!(vp, Dict{String, Any}(
        "op" => "request_pick",
        "request_id" => rid,
        "x" => Int32(x),
        "y" => Int32(y),
        "range" => Int32(max(0, Int(range))),
        "sorted" => sorted,
    ))
    t0 = time()
    while !isready(ch) && (time() - t0) < 10.0
        vp.open[] || return Tuple{UInt64, UInt32}[]
        sleep(0.002)
    end
    if !isready(ch)
        @lock vp.req_lock pop!(vp.pending_pick, rid, nothing)
        error("Timed out waiting for pick reply from viewer")
    end
    res = take!(ch)
    res isa Exception && throw(res)
    raw_hits = get(res, "hits", Any[])
    hits = Tuple{UInt64, UInt32}[]
    sizehint!(hits, length(raw_hits))
    for h in raw_hits
        push!(hits, (UInt64(h[1]), UInt32(h[2])))
    end
    return hits
end

function close_viewer!(vp::ViewerProcess)
    was_open = Threads.atomic_xchg!(vp.open, false)
    if was_open && !isnothing(vp.conn) && isopen(vp.conn)
        try
            @lock vp.write_lock begin
                write_frame(vp.conn, Dict{String, Any}("op" => "close"))
            end
        catch
        end
    end
    try
        !isnothing(vp.conn) && isopen(vp.conn) && close(vp.conn)
    catch
    end
    try
        isopen(vp.server) && close(vp.server)
    catch
    end
    t0 = time()
    while process_running(vp.proc) && (time() - t0) < 2.0
        sleep(0.01)
    end
    if process_running(vp.proc)
        try
            kill(vp.proc)
        catch
        end
    end
    ispath(vp.socket_path) && rm(vp.socket_path; force = true)
    return nothing
end
