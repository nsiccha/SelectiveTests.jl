# CLI-subprocess server runner: spawn a server command, wait for readiness,
# run the body, then terminate the server. The shape a test uses when the
# server must NOT share the test process (event loop, JIT, precompile).

"""
    with_server_subprocess(f, cmd; ready, timeout=120, poll=0.25, dir=pwd(), env, out=stderr, err=stderr)

Spawn `cmd` as a subprocess, poll `ready()` until it returns `true`, run `f()`,
then terminate the server (SIGTERM, SIGKILL after 5 s grace) and return `f()`'s
value. `ready` exceptions count as not-ready. Errors — after killing the
server — when `ready` never holds within `timeout` seconds, or when the server
exits early (its exit code is in the message). `env` (pairs) augments the child
environment; `JULIA_LOAD_PATH` defaults to the Pkg.test-safe `@:@stdlib` pin
unless overridden there. Stdio is inherited by default so a failed boot stays
diagnosable.
"""
function with_server_subprocess(f::Function, cmd::Cmd;
        ready::Function,
        timeout::Real=120, poll::Real=0.25,
        dir::AbstractString=pwd(),
        env::Vector{Pair{String,String}}=Pair{String,String}[],
        out::IO=stderr, err::IO=stderr)
    envdict = Dict{String,String}(k => v for (k, v) in _child_env())
    for (k, v) in env
        envdict[k] = v
    end
    proc = run(setenv(cmd, envdict; dir=dir), devnull, out, err; wait=false)
    t0 = time()
    while true
        up = try
            ready()
        catch
            false
        end
        up === true && break
        if !process_running(proc)
            code = try
                proc.exitcode
            catch
                "unknown"
            end
            try wait(proc) catch end
            error("SelectiveTests: server exited before becoming ready (exit $code): $cmd")
        end
        if time() - t0 >= timeout
            _terminate(proc)
            error("SelectiveTests: server never became ready within $(timeout)s: $cmd")
        end
        sleep(poll)
    end
    try
        return f()
    finally
        _terminate(proc)
    end
end

function _terminate(proc::Base.Process; grace::Real=5)
    if process_running(proc)
        try kill(proc) catch end
        t0 = time()
        while process_running(proc) && time() - t0 < grace
            sleep(0.05)
        end
        if process_running(proc)
            try kill(proc, Base.Libc.SIGKILL) catch end
        end
    end
    try wait(proc) catch end
    return nothing
end
