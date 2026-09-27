module SelectiveTests

using TOML, TestItemRunner

export SuiteKind, TestItemSuite, TestSetSuite, FixtureSuite, UnknownSuite
export ChangedFiles, Selection
export detect_suite, changed_files, select_reference
export CoverageMap, cov_has_hits, collect_src_hits
export build_map, load_map, save_map, select_coverage, select_affected
export run_selected, run_selection_subprocess
export with_server_subprocess

include("servers.jl")

"""
Suite layout kinds the selector understands.
"""
@enum SuiteKind TestItemSuite TestSetSuite FixtureSuite UnknownSuite

"""
Changed files split by git status. `added` covers status `A` plus untracked
files; everything else reported by the range is `modified`.
"""
struct ChangedFiles
    modified::Vector{String}
    added::Vector{String}
end

"""
Outcome of a selection query. `kind` is `:subset` (run exactly `files`),
`:full` (run everything; `reason` says why narrowing failed), or `:none`
(nothing could be affected). `notes` carries the skips and fallbacks.
"""
struct Selection
    kind::Symbol
    files::Vector{String}
    reason::String
    notes::Vector{String}
end

# Files whose change invalidates any narrowing: the environment plus the
# runner itself.
const FULL_FALLBACK = (
    "Project.toml",
    "Manifest.toml",
    "test/Project.toml",
    "test/Manifest.toml",
    "test/runtests.jl",
)

"""
    detect_suite(pkgdir) -> SuiteKind

Classify the test layout: a `test/runtests.jl` with `@testitem` files is a
`TestItemSuite`; with plain test files a `TestSetSuite`; standalone
`test/fixture_*.jl` scripts without a runner a `FixtureSuite`; anything else
`UnknownSuite`.
"""
function detect_suite(pkgdir::AbstractString)::SuiteKind
    testdir = joinpath(pkgdir, "test")
    isdir(testdir) || return UnknownSuite
    jlfiles = _jl_files(testdir)
    isempty(jlfiles) && return UnknownSuite
    has_runtests = isfile(joinpath(testdir, "runtests.jl"))
    has_testitem = any(f -> occursin("@testitem", read(f, String)), jlfiles)
    has_fixtures = any(f -> startswith(basename(f), "fixture_"), jlfiles)
    has_runtests && has_testitem && return TestItemSuite
    has_runtests && return TestSetSuite
    has_fixtures && return FixtureSuite
    return UnknownSuite
end

function _jl_files(dir::AbstractString)::Vector{String}
    out = String[]
    for (root, _, files) in walkdir(dir), f in files
        endswith(f, ".jl") && push!(out, joinpath(root, f))
    end
    return out
end

"""
    changed_files(pkgdir; base="HEAD~1", head="HEAD", include_uncommitted=true)

Collect the changed repo-relative paths for the range `base...head` plus,
unless `include_uncommitted` is false, staged, unstaged, and untracked files.
Rename/copy pairs contribute both sides as modified.
"""
function changed_files(pkgdir::AbstractString; base::AbstractString="HEAD~1",
                        head::AbstractString="HEAD",
                        include_uncommitted::Bool=true)::ChangedFiles
    _revok(pkgdir, base) || error("SelectiveTests: base does not resolve: $base")
    _revok(pkgdir, head) || error("SelectiveTests: head does not resolve: $head")
    modified = String[]
    added = String[]
    _ingest!(pkgdir, ["diff", "--name-status", base, head], modified, added)
    if include_uncommitted
        _ingest!(pkgdir, ["diff", "--name-status"], modified, added)
        _ingest!(pkgdir, ["diff", "--cached", "--name-status"], modified, added)
        for p in _lines(_git(pkgdir, ["ls-files", "--others", "--exclude-standard"]))
            push!(added, p)
        end
    end
    added_set = Set(added)
    return ChangedFiles(unique!(filter!(p -> p ∉ added_set, modified)),
                        unique!(added))
end

function _git(pkgdir::AbstractString, args::Vector{String})::String
    try
        return readchomp(`git -C $pkgdir $args`)
    catch err
        error("SelectiveTests: git failed in $pkgdir: $err")
    end
end

function _revok(pkgdir::AbstractString, ref::AbstractString)::Bool
    try
        revspec = "$(ref)^{commit}"
        run(pipeline(`git -C $pkgdir rev-parse --verify -q $revspec`,
                     stdout=devnull, stderr=devnull))
        return true
    catch
        return false
    end
end

function _lines(s::AbstractString)::Vector{String}
    return filter!(!isempty, split(s, '\n'))
end

function _ingest!(pkgdir::AbstractString, args::Vector{String},
                  modified::Vector{String}, added::Vector{String})
    for line in _lines(_git(pkgdir, args))
        cols = split(line, '\t')
        isempty(cols) && continue
        st = cols[1]
        if startswith(st, "R") || startswith(st, "C")
            length(cols) >= 3 || continue
            push!(modified, String(cols[2]))
            push!(modified, String(cols[3]))
        elseif length(cols) >= 2
            push!(st == "A" ? added : modified, String(cols[2]))
        end
    end
end

"""
    select_reference(pkgdir, changed) -> Selection

Map changed files to test files by literal reference: a changed test selects
itself; a changed `src/<f>.jl` selects tests mentioning `<f>.jl`; a changed
`skills/<name>/...` selects tests matching `skills/<name>` or `"<name>"`;
anything else matches on basename. Conservative throughout: unresolvable
changes select everything (`:full`), and only provably-unaffected changes
select nothing (`:none`).
"""
function select_reference(pkgdir::AbstractString, changed::ChangedFiles;
                          notes::Union{Vector{String},Nothing}=nothing,
                          coverage::Function=((p) -> String[]))::Selection
    notes = notes === nothing ? String[] : notes
    testdir = joinpath(pkgdir, "test")
    testfiles = isdir(testdir) ? _jl_files(testdir) : String[]
    selected = Set{String}()
    seen = Set{String}()
    added_set = Set(changed.added)
    full_reason = nothing
    for p in Iterators.flatten((changed.modified, changed.added))
        p in seen && continue
        push!(seen, p)
        if p in FULL_FALLBACK
            full_reason = "changed $p selects the whole suite"
            break
        elseif startswith(p, "test/") && endswith(p, ".jl")
            f = joinpath(pkgdir, split(p, '/')...)
            if isfile(f) && !islink(f)
                push!(selected, p)
            else
                push!(notes, "$p changed but is not a runnable file anymore — skipped")
            end
        elseif startswith(p, "src/") && endswith(p, ".jl")
            hits = _mentioning(pkgdir, testfiles, (basename(p),))
            covhits = coverage(p)
            if !isempty(hits) || !isempty(covhits)
                union!(selected, hits)
                union!(selected, covhits)
            elseif p in added_set
                push!(notes, "$p is new and unreferenced — no unchanged test can depend on it")
            else
                full_reason = "changed $p is referenced by no test — no signal to select on"
                break
            end
        elseif startswith(p, "skills/")
            parts = split(p, '/')
            if length(parts) >= 2
                name = parts[2]
                hits = _mentioning(pkgdir, testfiles, ("skills/$name", "\"$name\""))
                isempty(hits) ? push!(notes, "$p pins no test — skipped") :
                                union!(selected, hits)
            else
                push!(notes, "$p pins no test — skipped")
            end
        else
            hits = _mentioning(pkgdir, testfiles, (basename(p),))
            covhits = endswith(p, ".jl") ? coverage(p) : String[]
            if !isempty(hits) || !isempty(covhits)
                union!(selected, hits)
                union!(selected, covhits)
            else
                push!(notes, "$p is referenced by no test — skipped")
            end
        end
    end
    full_reason !== nothing &&
        return Selection(:full, String[], full_reason, notes)
    isempty(selected) &&
        return Selection(:none, String[], "no test references the changed files", notes)
    return Selection(:subset, sort!(collect(selected)), "", notes)
end

function _mentioning(pkgdir::AbstractString, testfiles::Vector{String},
                     needles::Tuple)::Vector{String}
    out = String[]
    for f in testfiles
        text = read(f, String)
        any(n -> occursin(n, text), needles) || continue
        push!(out, replace(relpath(f, pkgdir), '\\' => '/'))
    end
    return out
end

# ── Coverage ─────────────────────────────────────────────────────────────

"""
Executed-lines map: which `.jl` files each test file executed, plus build
provenance. Built by [`build_map`](@ref), stored as TOML.
"""
struct CoverageMap
    generated_at_commit::String
    generated_at::String
    map::Dict{String,Vector{String}}
    skipped::Vector{String}
    failures::Vector{String}
end

"""
    cov_has_hits(path) -> Bool

Whether a `.cov` file records at least one executed line (a count starting
with 1–9; `0` and `-` lines do not count).
"""
function cov_has_hits(path::AbstractString)::Bool
    for line in eachline(path)
        s = lstrip(line)
        isempty(s) && continue
        c = first(s)
        ('1' <= c <= '9') && return true
    end
    return false
end

_relslash(pkgdir, f) = replace(relpath(f, pkgdir), '\\' => '/')

"""
    collect_src_hits(pkgdir) -> Set{String}

Scan `src/**/*.cov` plus root-level `*.cov` for files with hits and return
the covered repo-relative `.jl` paths.
"""
function collect_src_hits(pkgdir::AbstractString)::Set{String}
    hits = Set{String}()
    cands = String[]
    srcdir = joinpath(pkgdir, "src")
    if isdir(srcdir)
        for (root, _, files) in walkdir(srcdir), f in files
            endswith(f, ".cov") && push!(cands, joinpath(root, f))
        end
    end
    for f in readdir(pkgdir)
        full = joinpath(pkgdir, f)
        endswith(f, ".cov") && isfile(full) && push!(cands, full)
    end
    for c in cands
        m = match(r"^(.+\.jl)\.[^.]+\.cov$", basename(c))
        m === nothing && continue
        cov_has_hits(c) || continue
        push!(hits, _relslash(pkgdir, joinpath(dirname(c), m.captures[1])))
    end
    return hits
end

function _sweep_repo_cov(pkgdir::AbstractString)
    for sub in ("src", "test")
        d = joinpath(pkgdir, sub)
        isdir(d) || continue
        for (root, _, files) in walkdir(d), f in files
            endswith(f, ".cov") && rm(joinpath(root, f); force=true)
        end
    end
    for f in readdir(pkgdir)
        full = joinpath(pkgdir, f)
        endswith(f, ".cov") && isfile(full) && rm(full; force=true)
    end
    return nothing
end

function _sweep_depot_cov()
    pkgs = joinpath(DEPOT_PATH[1], "packages")
    isdir(pkgs) || return nothing
    for (root, _, files) in walkdir(pkgs), f in files
        endswith(f, ".cov") && rm(joinpath(root, f); force=true)
    end
    return nothing
end

function save_map(path::AbstractString, cov::CoverageMap)::String
    d = Dict{String,Any}(
        "meta" => Dict{String,Any}(
            "generated_at_commit" => cov.generated_at_commit,
            "generated_at" => cov.generated_at,
            "skipped" => cov.skipped,
            "failures" => cov.failures),
        "map" => Dict{String,Any}(k => v for (k, v) in cov.map))
    open(path, "w") do io
        TOML.print(io, d)
    end
    return path
end

function load_map(path::AbstractString)::CoverageMap
    d = TOML.parsefile(path)
    meta = get(d, "meta", Dict{String,Any}())
    raw = get(d, "map", Dict{String,Any}())
    m = Dict{String,Vector{String}}()
    for (k, v) in raw
        m[String(k)] = Vector{String}(v)
    end
    return CoverageMap(string(get(meta, "generated_at_commit", "")),
                       string(get(meta, "generated_at", "")),
                       m,
                       Vector{String}(get(meta, "skipped", String[])),
                       Vector{String}(get(meta, "failures", String[])))
end

# Subprocess children inherit the caller's environment, which under Pkg.test
# can carry a JULIA_LOAD_PATH that hides even stdlibs (observed: `using Pkg`
# failing with "not found in current path"). Pin a self-contained load path:
# the active project plus the stdlib dir.
function _child_env()::Vector{Pair{String,String}}
    sep = Sys.iswindows() ? ";" : ":"
    return ["JULIA_LOAD_PATH" => "@" * sep * "@stdlib"]
end

function _run_timeout(cmd::Cmd, dir::AbstractString, timeout::Real,
                      env::Vector{Pair{String,String}}=_child_env())::Bool
    proc = run(setenv(cmd, env...; dir=dir); wait=false)
    killer = Timer(timeout) do _
        try kill(proc) catch end
    end
    try
        wait(proc)
    finally
        close(killer)
    end
    return success(proc)
end

function _project_name(pkgdir::AbstractString)::String
    pf = joinpath(pkgdir, "Project.toml")
    isfile(pf) || return ""
    try
        return string(get(TOML.parsefile(pf), "name", ""))
    catch
        return ""
    end
end

function _loads_package(path::AbstractString, pkgname::AbstractString)::Bool
    isempty(pkgname) && return false
    rx = Regex("^\\s*(using|import)\\s+" * pkgname * "\\b")
    for line in eachline(path)
        occursin(rx, line) && return true
    end
    return false
end

"""
    build_map(pkgdir; out, timeout=180, verbose=false) -> path

Measure the fixture→src coverage map: run each runnable test file once under
`--code-coverage=user` and record which `.jl` files received hits. Only
runnable-per-file suites qualify (`TestItemSuite`, `FixtureSuite`);
`TestSetSuite` is reference-only and errors here. Fixture files that load the
package under test are skipped (compiling it on a serving host is the
precompile hazard). Failing files keep their partial coverage and are listed
in the map trailer.
"""
function build_map(pkgdir::AbstractString;
                   out::AbstractString=joinpath(pkgdir, "test", "SelectiveTests-map.toml"),
                   timeout::Real=180, verbose::Bool=false)::String
    kind = detect_suite(pkgdir)
    kind == TestSetSuite &&
        error("SelectiveTests: per-file coverage needs runnable-per-file suites; $pkgdir is a TestSetSuite (reference-only)")
    kind == UnknownSuite &&
        error("SelectiveTests: unknown suite layout at $pkgdir")
    testdir = joinpath(pkgdir, "test")
    alljl = sort!([_relslash(pkgdir, f) for f in _jl_files(testdir)])
    pkgname = kind == FixtureSuite ? _project_name(pkgdir) : ""
    m = Dict{String,Vector{String}}()
    skipped = String[]
    runnable = String[]
    for f in alljl
        absf = joinpath(pkgdir, split(f, '/')...)
        if !isempty(pkgname) && _loads_package(absf, pkgname)
            push!(skipped, f)
            continue
        end
        if kind == TestItemSuite && !occursin("@testitem", read(absf, String))
            # No items: never runs under TIR, so no entry (unlike fixture
            # suites, TIR has no skipped/absent distinction to preserve).
            continue
        end
        push!(runnable, f)
    end
    failures = String[]
    _sweep_repo_cov(pkgdir)
    _sweep_depot_cov()
    for (i, f) in enumerate(runnable)
        absf = joinpath(pkgdir, split(f, '/')...)
        _sweep_repo_cov(pkgdir)
        ok = _run_one(pkgdir, kind, absf, timeout)
        hits = collect_src_hits(pkgdir)
        _sweep_repo_cov(pkgdir)
        m[f] = sort!(collect(hits))
        ok || push!(failures, f)
        verbose && @info "SelectiveTests: measured" i length(runnable) f hits = length(hits)
    end
    _sweep_repo_cov(pkgdir)
    _sweep_depot_cov()
    head = try
        _git(pkgdir, ["rev-parse", "HEAD"])
    catch
        ""
    end
    save_map(out, CoverageMap(head, string(Libc.time()), m, skipped, failures))
    return out
end

function _run_one(pkgdir::AbstractString, kind::SuiteKind, absfile::AbstractString,
                  timeout::Real)::Bool
    jl = joinpath(Sys.BINDIR, "julia")
    if kind == TestItemSuite
        testenv = joinpath(pkgdir, "test")
        isfile(joinpath(testenv, "Project.toml")) ||
            error("SelectiveTests: no test environment at $testenv")
        code = "using TestItemRunner; TestItemRunner.run_tests(\"test\"; filter = ti -> abspath(string(ti.filename)) == abspath(ARGS[1]))"
        cmd = `$jl --startup-file=no --code-coverage=user --project=$testenv -e $code $absfile`
    else
        cmd = `$jl --startup-file=no --code-coverage=user --project=$pkgdir $absfile`
    end
    return _run_timeout(cmd, pkgdir, timeout)
end

"""
    select_coverage(cov, srcpath) -> Vector{String}

Test files whose coverage list contains `srcpath` (exact match), sorted.
"""
select_coverage(cov::CoverageMap, srcpath::AbstractString) =
    sort!([f for (f, srcs) in cov.map if srcpath in srcs])

"""
    select_affected(pkgdir, changed; map_path, notes) -> Selection

Union of the reference signal and the coverage map (default
`test/SelectiveTests-map.toml`). Without a map, degrades to
[`select_reference`](@ref) with a note.
"""
function select_affected(pkgdir::AbstractString, changed::ChangedFiles;
                         map_path::AbstractString=joinpath(pkgdir, "test", "SelectiveTests-map.toml"),
                         notes::Union{Vector{String},Nothing}=nothing)::Selection
    mynotes = notes === nothing ? String[] : notes
    if !isfile(map_path)
        push!(mynotes, "no coverage map at $map_path — reference selection only")
        return select_reference(pkgdir, changed; notes=mynotes)
    end
    cov = load_map(map_path)
    return select_reference(pkgdir, changed; notes=mynotes,
                            coverage=(p -> select_coverage(cov, p)))
end

# ── TestItemRunner driver ────────────────────────────────────────────────

"""
    run_selected(pkgdir, files; verbose=false) -> true

Run exactly `files` (repo-relative test paths) in-process through
TestItemRunner's filename filter. Needs a `TestItemSuite`; throws the
underlying test failure like `@run_package_tests` does.
"""
function run_selected(pkgdir::AbstractString, files::Vector{String}; verbose::Bool=false)::Bool
    detect_suite(pkgdir) == TestItemSuite ||
        error("SelectiveTests: run_selected needs a TestItemSuite")
    want = Set(abspath.(joinpath.(pkgdir, files)))
    testdir = abspath(joinpath(pkgdir, "test"))
    # Run in a fresh task: testsets live in task-local storage, so without
    # this an inner run nested inside an outer testset leaks its results
    # upward and the returned root looks clean while failing.
    ts = fetch(@async TestItemRunner.run_tests(
        testdir; filter=ti -> abspath(string(ti.filename)) in want,
        verbose=verbose))
    ts.anynonpass && error("SelectiveTests: selection had failing tests")
    return true
end

"""
    run_selection_subprocess(pkgdir, files; timeout=600, offline=false) -> (exitcode, output)

Run exactly `files` in a fresh `julia --project=test` process (the shape a
web server uses: no in-process test state). Returns the exit code and the
captured output. `offline=true` sets `JULIA_PKG_OFFLINE` in the child.
"""
function run_selection_subprocess(pkgdir::AbstractString, files::Vector{String};
                                  timeout::Real=600, offline::Bool=false)::Tuple{Int,String}
    detect_suite(pkgdir) == TestItemSuite ||
        error("SelectiveTests: run_selection_subprocess needs a TestItemSuite")
    testenv = joinpath(pkgdir, "test")
    isfile(joinpath(testenv, "Project.toml")) ||
        error("SelectiveTests: no test environment at $testenv")
    code = "using TestItemRunner; " *
        "try; TestItemRunner.run_tests(\"test\"; filter = ti -> abspath(string(ti.filename)) in Set(abspath.(ARGS))); exit(0); " *
        "catch err; showerror(stdout, err); println(); exit(1); end"
    jl = joinpath(Sys.BINDIR, "julia")
    absfiles = abspath.(joinpath.(pkgdir, files))
    cmd = `$jl --startup-file=no --project=$testenv -e $code $absfiles`
    pairs = _child_env()
    offline && push!(pairs, "JULIA_PKG_OFFLINE" => "true")
    out = IOBuffer()
    proc = run(setenv(cmd, pairs...; dir=pkgdir), devnull, out, out; wait=false)
    killer = Timer(timeout) do _
        try kill(proc) catch end
    end
    try
        wait(proc)
    finally
        close(killer)
    end
    return (Int(proc.exitcode), String(take!(out)))
end

end # module
