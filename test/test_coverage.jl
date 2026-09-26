@testsnippet CovHelpers begin
    using SelectiveTests

    const MINIP_UUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    function _mkrepo!(files::Dict{String,String})
        dir = mktempdir()
        for (p, content) in files
            fp = joinpath(dir, split(p, '/')...)
            mkpath(dirname(fp))
            write(fp, content)
        end
        run(`git -C $dir -c init.defaultBranch=main init -q`)
        run(`git -C $dir -c user.email=t@t -c user.name=t commit -q --allow-empty -m root`)
        run(`git -C $dir add -A`)
        run(`git -C $dir -c user.email=t@t -c user.name=t commit -qm init`)
        return dir
    end

    function _commit_change!(dir, path)
        open(joinpath(dir, split(path, '/')...), "a") do io
            print(io, "# touched\n")
        end
        run(`git -C $dir add -A`)
        run(`git -C $dir -c user.email=t@t -c user.name=t commit -qm change`)
    end

    # Tiny runnable TestItemRunner package. `fail_b` makes test/b.jl fail.
    function _mktirpkg!(; fail_b::Bool=false)
        dir = mktempdir()
        write(joinpath(dir, "Project.toml"), "name = \"MiniP\"\nuuid = \"$MINIP_UUID\"\n")
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "src", "MiniP.jl"), "module MiniP\nf1() = 1\nf2() = 2\nend\n")
        mkpath(joinpath(dir, "test"))
        write(joinpath(dir, "test", "Project.toml"),
            "[deps]\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\nTestItemRunner = \"f8b46487-2199-4994-9208-9a1283c18c0a\"\n")
        write(joinpath(dir, "test", "a.jl"),
            "@testitem \"a\" begin\ninclude(joinpath(dirname(@__FILE__), \"..\", \"src\", \"MiniP.jl\"))\n@test MiniP.f1() == 1\nend\n")
        bbody = fail_b ? "@test 1 == 2\n" :
            "include(joinpath(dirname(@__FILE__), \"..\", \"src\", \"MiniP.jl\"))\n@test MiniP.f2() == 2\n"
        write(joinpath(dir, "test", "b.jl"), "@testitem \"b\" begin\n" * bbody * "end\n")
        write(joinpath(dir, "test", "runtests.jl"), "using TestItemRunner\n@run_package_tests()\n")
        return dir
    end

    function _instantiate!(testdir)
        jl = joinpath(Sys.BINDIR, "julia")
        code = "using Pkg; Pkg.instantiate()"
        sep = Sys.iswindows() ? ";" : ":"
        run(setenv(`$jl --startup-file=no --project=$testdir -e $code`,
                   "JULIA_LOAD_PATH" => "@" * sep * "@stdlib"))
    end
end

@testitem "cov file parsing" setup=[CovHelpers] begin
    dir = mktempdir()
    write(joinpath(dir, "hit.cov"), "        1 f() = 1\n        - # comment\n        0 g() = 2\n")
    write(joinpath(dir, "miss.cov"), "        - # comment\n        0 g() = 2\n")
    @test cov_has_hits(joinpath(dir, "hit.cov"))
    @test !cov_has_hits(joinpath(dir, "miss.cov"))
end

@testitem "collect src hits" setup=[CovHelpers] begin
    dir = mktempdir()
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "src", "a.jl.111.cov"), "        3 f() = 1\n")
    write(joinpath(dir, "src", "b.jl.222.cov"), "        0 g() = 2\n")
    write(joinpath(dir, "test", "x.jl") |> dirname |> d -> (mkpath(joinpath(dir, "test")); joinpath(dir, "test", "x.jl.333.cov")),
        "        9 @test true\n")
    @test collect_src_hits(dir) == Set(["src/a.jl"])
end

@testitem "map save/load roundtrip" setup=[CovHelpers] begin
    cov = CoverageMap("abc123", "12345",
                      Dict("test/a.jl" => ["src/x.jl"], "test/b.jl" => String[]),
                      ["test/c.jl"], String[])
    path = joinpath(mktempdir(), "map.toml")
    save_map(path, cov)
    back = load_map(path)
    @test back.generated_at_commit == "abc123"
    @test back.map == cov.map
    @test back.skipped == ["test/c.jl"]
end

@testitem "select_affected unions signals" setup=[CovHelpers] begin
    dir = _mkrepo!(Dict("src/foo.jl" => "f() = 1\n",
                        "test/runtests.jl" => "x\n",
                        "test/a.jl" => "# uses foo.jl\n",
                        "test/b.jl" => "# unrelated\n"))
    cov = CoverageMap("c", "t", Dict("test/b.jl" => ["src/foo.jl"]), String[], String[])
    map_path = joinpath(dir, "test", "SelectiveTests-map.toml")
    save_map(map_path, cov)
    # NOTE: saving the map dirties the worktree; commit it so the range below
    # sees only the src change.
    run(`git -C $dir add -A`)
    run(`git -C $dir -c user.email=t@t -c user.name=t commit -qm map`)
    _commit_change!(dir, "src/foo.jl")
    sel = select_affected(dir, changed_files(dir))
    @test sel.kind == :subset
    @test sel.files == ["test/a.jl", "test/b.jl"]
end

@testitem "orphan downgraded by coverage" setup=[CovHelpers] begin
    dir = _mkrepo!(Dict("src/orphan.jl" => "g() = 2\n",
                        "test/runtests.jl" => "x\n",
                        "test/a.jl" => "# unrelated\n"))
    cov = CoverageMap("c", "t", Dict("test/a.jl" => ["src/orphan.jl"]), String[], String[])
    map_path = joinpath(dir, "test", "SelectiveTests-map.toml")
    save_map(map_path, cov)
    run(`git -C $dir add -A`)
    run(`git -C $dir -c user.email=t@t -c user.name=t commit -qm map`)
    _commit_change!(dir, "src/orphan.jl")
    sel = select_affected(dir, changed_files(dir))
    @test sel.kind == :subset
    @test sel.files == ["test/a.jl"]
end

@testitem "missing map degrades to reference" setup=[CovHelpers] begin
    dir = _mkrepo!(Dict("src/foo.jl" => "f() = 1\n",
                        "test/runtests.jl" => "x\n",
                        "test/a.jl" => "# uses foo.jl\n"))
    _commit_change!(dir, "src/foo.jl")
    sel = select_affected(dir, changed_files(dir))
    @test sel.kind == :subset
    @test sel.files == ["test/a.jl"]
    @test any(n -> occursin("no coverage map", n), sel.notes)
end

@testitem "run_selected runs only the selection" setup=[CovHelpers] begin
    dir = _mktirpkg!(fail_b=true)
    @test run_selected(dir, ["test/a.jl"]) === true
    @test_throws Exception run_selected(dir, ["test/b.jl"])
end

@testitem "build_map measures a tiny suite" setup=[CovHelpers] begin
    dir = _mktirpkg!()
    _instantiate!(joinpath(dir, "test"))
    out = build_map(dir)
    cov = load_map(out)
    @test sort!(collect(keys(cov.map))) == ["test/a.jl", "test/b.jl"]
    @test cov.map["test/a.jl"] == ["src/MiniP.jl"]
    @test cov.map["test/b.jl"] == ["src/MiniP.jl"]
    @test isempty(cov.failures)
end

@testitem "subprocess selection" setup=[CovHelpers] begin
    dir = _mktirpkg!(fail_b=true)
    _instantiate!(joinpath(dir, "test"))
    code_a, _ = run_selection_subprocess(dir, ["test/a.jl"])
    @test code_a == 0
    code_b, out_b = run_selection_subprocess(dir, ["test/b.jl"])
    @test code_b != 0
    @test occursin("b", out_b)
end
