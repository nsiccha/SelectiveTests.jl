@testsnippet ServerHelpers begin
    using SelectiveTests, Sockets, Test

    _sjl() = joinpath(Sys.BINDIR, "julia")

    # A free loopback port: bind ephemeral, read it back, close. TOCTOU-safe
    # enough for serial tests (TIR runs items in one process, in order).
    function _free_port()
        s = Sockets.listen(Sockets.IPv4(127, 0, 0, 1), 0)
        port = Sockets.getsockname(s)[2]
        close(s)
        return port
    end

    # Ready probe: a TCP connect succeeds.
    function _tcp_up(port)
        try
            s = Sockets.connect(Sockets.IPv4(127, 0, 0, 1), port)
            close(s)
            return true
        catch
            return false
        end
    end
end

@testitem "server subprocess runs body then kills" setup=[ServerHelpers] begin
    port = _free_port()
    code = "using Sockets; s = listen(IPv4(127,0,0,1), $port); while true; accept(s); end"
    cmd = `$(_sjl()) --startup-file=no -e $code`
    seen = Ref(false)
    with_server_subprocess(cmd; ready=() -> _tcp_up(port), timeout=60,
                           out=devnull, err=devnull) do
        seen[] = true
    end
    @test seen[]
    @test !_tcp_up(port)
end

@testitem "never-ready server errors and is reaped" setup=[ServerHelpers] begin
    marker = "selectivetests_reap_$(getpid())"
    code = "#= $marker =#; sleep(30)"
    cmd = `$(_sjl()) --startup-file=no -e $code`
    @test_throws ErrorException with_server_subprocess(
        cmd; ready=() -> false, timeout=2, out=devnull, err=devnull) do
        error("must not run")
    end
    # The bracket keeps pgrep from matching its own command line.
    pattern = "[s]electivetests_reap_$(getpid())"
    out = try
        readchomp(`pgrep -f $pattern`)
    catch
        ""
    end
    @test isempty(out)
end

@testitem "crashed server errors fast" setup=[ServerHelpers] begin
    cmd = `$(_sjl()) --startup-file=no -e "exit(3)"`
    t0 = time()
    err = try
        with_server_subprocess(cmd; ready=() -> false, timeout=60,
                              out=devnull, err=devnull) do
            nothing
        end
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("exit 3", sprint(showerror, err))
    @test time() - t0 < 30
end

@testitem "sigterm-ignoring server is sigkilled" setup=[ServerHelpers] begin
    # The child ignores SIGTERM; only the SIGKILL escalation reaps it.
    marker = "selectivetests_kill_$(getpid())"
    code = "#= $marker =#; ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), 15, Ptr{Cvoid}(1)); sleep(30)"
    cmd = `$(_sjl()) --startup-file=no -e $code`
    t0 = time()
    @test_throws ErrorException with_server_subprocess(
        cmd; ready=() -> false, timeout=2, out=devnull, err=devnull) do
        nothing
    end
    @test time() - t0 < 30
    pattern = "[s]electivetests_kill_$(getpid())"
    out = try
        readchomp(`pgrep -f $pattern`)
    catch
        ""
    end
    @test isempty(out)
end

@testitem "server child inherits caller env" setup=[ServerHelpers] begin
    port = _free_port()
    val = "envprobe-$(getpid())"
    code = "using Sockets; println(ENV[\"SELECTIVETESTS_ENV_PROBE\"]); flush(stdout); " *
           "s = listen(IPv4(127,0,0,1), $port); while true; accept(s); end"
    cmd = `$(_sjl()) --startup-file=no -e $code`
    out = IOBuffer()
    got = Ref("")
    withenv("SELECTIVETESTS_ENV_PROBE" => val) do
        with_server_subprocess(cmd; ready=() -> _tcp_up(port), timeout=60,
                               out=out, err=devnull) do
            t0 = time()
            while time() - t0 < 10
                got[] *= String(take!(out))
                occursin(val, got[]) && break
                sleep(0.1)
            end
        end
    end
    @test occursin(val, got[])
end
