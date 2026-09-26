using Test, SelectiveTests

# Build a throwaway git repo from path=>content pairs, committed once.
function _mkrepo!(files::Dict{String,String})
    dir = mktempdir()
    for (p, content) in files
        fp = joinpath(dir, split(p, '/')...)
        mkpath(dirname(fp))
        write(fp, content)
    end
    run(`git -C $dir -c init.defaultBranch=main init -q`)
    run(`git -C $dir add -A`)
    run(`git -C $dir -c user.email=t@t -c user.name=t commit -qm init`)
    return dir
end

function _modify!(dir, path, content="# touched\n")
    open(joinpath(dir, split(path, '/')...), "a") do io
        print(io, content)
    end
end

@testitem "detect suite kinds" begin
    tir = _mkrepo!(Dict("test/runtests.jl" => "using TestItemRunner\n@run_package_tests()\n",
                        "test/a.jl" => "@testitem \"a\" begin\n@test 1 == 1\nend\n"))
    @test detect_suite(tir) == TestItemSuite
    ts = _mkrepo!(Dict("test/runtests.jl" => "using Test\n@testset \"x\" begin\n@test true\nend\n"))
    @test detect_suite(ts) == TestSetSuite
    fx = _mkrepo!(Dict("test/fixture_x.jl" => "println(\"hi\")\n"))
    @test detect_suite(fx) == FixtureSuite
    @test detect_suite(mktempdir()) == UnknownSuite
end

@testitem "changed test selects itself" begin
    dir = _mkrepo!(Dict("test/runtests.jl" => "x\n", "test/a.jl" => "x\n"))
    _modify!(dir, "test/a.jl")
    sel = select_reference(dir, changed_files(dir))
    @test sel.kind == :subset
    @test sel.files == ["test/a.jl"]
end

@testitem "src change selects mentioning tests only" begin
    dir = _mkrepo!(Dict("src/foo.jl" => "f() = 1\n",
                        "test/runtests.jl" => "include(\"a.jl\")\ninclude(\"b.jl\")\n",
                        "test/a.jl" => "# uses foo.jl\n",
                        "test/b.jl" => "# unrelated\n"))
    _modify!(dir, "src/foo.jl")
    sel = select_reference(dir, changed_files(dir))
    @test sel.kind == :subset
    @test sel.files == ["test/a.jl"]
end

@testitem "orphan src change selects full" begin
    dir = _mkrepo!(Dict("src/orphan.jl" => "g() = 2\n",
                        "test/runtests.jl" => "x\n",
                        "test/a.jl" => "# unrelated\n"))
    _modify!(dir, "src/orphan.jl")
    sel = select_reference(dir, changed_files(dir))
    @test sel.kind == :full
    @test occursin("orphan", sel.reason)
end

@testitem "added src file is ignored" begin
    dir = _mkrepo!(Dict("test/runtests.jl" => "x\n", "test/a.jl" => "x\n"))
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "src", "new.jl"), "h() = 3\n")
    sel = select_reference(dir, changed_files(dir))
    @test sel.kind == :none
end

@testitem "environment change selects full" begin
    dir = _mkrepo!(Dict("Project.toml" => "name=\"P\"\n",
                        "test/runtests.jl" => "x\n", "test/a.jl" => "x\n"))
    _modify!(dir, "Project.toml")
    sel = select_reference(dir, changed_files(dir))
    @test sel.kind == :full
end

@testitem "docs change selects none" begin
    dir = _mkrepo!(Dict("README.md" => "hi\n",
                        "test/runtests.jl" => "x\n", "test/a.jl" => "x\n"))
    _modify!(dir, "README.md")
    sel = select_reference(dir, changed_files(dir))
    # README basename is unreferenced: the contract is ignore-with-note.
    @test sel.kind == :none
end

@testitem "skills change selects skill readers" begin
    dir = _mkrepo!(Dict("skills/widgets/SKILL.md" => "how\n",
                        "test/fixture_w.jl" => "read(joinpath(ROOT, \"skills\", \"widgets\", \"SKILL.md\"))\n",
                        "test/fixture_q.jl" => "# unrelated\n"))
    _modify!(dir, "skills/widgets/SKILL.md")
    sel = select_reference(dir, changed_files(dir))
    @test sel.kind == :subset
    @test sel.files == ["test/fixture_w.jl"]
end
