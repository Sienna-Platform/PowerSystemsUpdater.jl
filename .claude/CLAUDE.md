# PowerSystemsUpdater.jl

Upgrades PowerSystems JSON files from the PSY5 specification to the PSY6 OpenAPI
JSON document, producing PSY6-compatible cases.

- **Depends on IS4** (`InfrastructureSystems.jl`, psy6 line) for time series and
  other object conversions between the PSY5 and PSY6 data models.
- **No PSY6 dependency.** Write output cases with the OpenAPI model subpackages
  (`PowerCoreOpenAPIModels`, `PowerOperationsOpenAPIModels`, and the others in `Project.toml`),
  not `PowerSystems.jl` (PSY6).
- **Test against PSY6.** Tests may load produced cases with PSY6 to confirm
  compatibility, but PSY6 stays a test-only dependency, never a package dependency.
- **Load PSY5 JSON with `JSON.jl`.** Read source PSY5 case files with `JSON.jl`,
  not PSY5 itself.
- **Reference test data lives in `data/`.** PSY5 sample cases and their expected
  PSY6 outputs for tests belong in the `data` folder.

## Commands

```sh
julia --project=test -e 'using Pkg; Pkg.instantiate()'
julia --project=test test/runtests.jl                  # full suite
julia --project=test test/runtests.jl test_convert     # one file (@includetests, stem without .jl)
julia --project=docs docs/make.jl
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
```

The shared Sienna rules load from the import below; the `sienna-dev` skill holds the cross-package
context; the `sienna-dev` and `sienna-reviewer` subagents implement and review.

@Sienna.md
