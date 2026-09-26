# SelectiveTests.jl

Affected-only test selection for Julia packages: given a git range, run
exactly the tests that could observe the change — instead of the whole suite.

Status: reference selection plus suite detection (this commit). Coverage-map
build/lookup, the TestItemRunner filter driver, and the CLI-subprocess web
runner follow.

## Quick sketch

```julia
using SelectiveTests
detect_suite(".")                     # TestItemSuite | TestSetSuite | ...
ch = changed_files(".")               # HEAD~1..HEAD + uncommitted
sel = select_reference(".", ch)        # Selection(:subset, files, "", notes)
sel.kind == :full && run_everything() # narrowing failed; reason says why
sel.kind == :none && skip()           # provably unaffected
```

Selection is conservative throughout: unresolvable changes select everything,
and only provably-unaffected changes select nothing.
