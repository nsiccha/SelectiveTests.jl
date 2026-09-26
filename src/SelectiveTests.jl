module SelectiveTests

export SuiteKind, TestItemSuite, TestSetSuite, FixtureSuite, UnknownSuite
export ChangedFiles, Selection
export detect_suite, changed_files, select_reference

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
                          notes::Union{Vector{String},Nothing}=nothing)::Selection
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
            if !isempty(hits)
                union!(selected, hits)
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
            isempty(hits) ? push!(notes, "$p is referenced by no test — skipped") :
                            union!(selected, hits)
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

end # module
