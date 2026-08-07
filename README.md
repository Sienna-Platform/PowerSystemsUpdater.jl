# PowerSystemsUpdater

[![main - CI](https://github.com/Sienna-Platform/PowerSystemsUpdater.jl/workflows/main%20-%20CI/badge.svg)](https://github.com/Sienna-Platform/PowerSystemsUpdater.jl/actions/workflows/main-tests.yml)
[![codecov](https://codecov.io/gh/Sienna-Platform/PowerSystemsUpdater.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/Sienna-Platform/PowerSystemsUpdater.jl)
[![Documentation Build](https://github.com/Sienna-Platform/PowerSystemsUpdater.jl/workflows/Documentation/badge.svg?)](https://sienna-platform.github.io/PowerSystemsUpdater.jl/stable)
[<img src="https://img.shields.io/badge/slack-@Sienna/PowerSystemsUpdater-sienna.svg?logo=slack">](https://join.slack.com/t/core-sienna/shared_invite/zt-glam9vdu-o8A9TwZTZqqNTKHa7q3BpQ)

Upgrades serialized [PowerSystems.jl](https://github.com/NREL-Sienna/PowerSystems.jl) v5
systems to the PSY6 data model.

Reading a PSY5 `System` JSON bundle, it writes a PSY6 `SystemDocument` conforming to
[SiennaSchemas](https://github.com/Sienna-Platform/SiennaSchemas), via the generated
serialization in
[PowerOpenAPIModels.jl](https://github.com/Sienna-Platform/PowerOpenAPIModels). The HDF5
time-series sidecar is carried across unchanged; only its metadata is translated.

```julia
using PowerSystemsUpdater

report = convert_system("path/to/psy5_system", "path/to/output")
```

The output directory receives `system.json` and, when the source has time series,
`time_series.h5`.

The upgrade is not a rename. Component identity moves from UUIDs to document-wide integer
ids, `SYSTEM_BASE` disappears, transformers split into a container plus per-arc circuits,
reserve direction moves from a type parameter to a field, and nested cost curves acquire the
discriminators PSY5 never carried. `docs/src/explanation/psy5_to_psy6_component_changes.md`
covers every such difference.

The returned `ConversionReport` records what could not be carried across — a PSY5 type with
no PSY6 counterpart, a field the schema has no home for — so gaps surface as findings rather
than as silently missing data. That reporting is the point as much as the conversion is: this
package doubles as a conformance exercise for SiennaSchemas and the generated serde, run
against a real corpus of systems.

## Local setup

`PowerOpenAPIModels` and `InfrastructureSystems` are **not registered** — both are resolved by
relative path, so they must be cloned as **siblings** of this repository:

```
<workspace>/
├── PowerSystemsUpdater.jl     # this repo
├── PowerOpenAPIModels/        # git@github.com:Sienna-Platform/PowerOpenAPIModels.git
└── InfrastructureSystems.jl   # git@github.com:Sienna-Platform/InfrastructureSystems.jl.git
```

```bash
cd <workspace>
git clone git@github.com:Sienna-Platform/PowerOpenAPIModels.git
git clone git@github.com:Sienna-Platform/InfrastructureSystems.jl.git
cd PowerSystemsUpdater.jl
```

`PowerOpenAPIModels` is a monorepo: the umbrella package lives at
`PowerOpenAPIModels/PowerOpenAPIModels.jl` and depends on four unregistered sub-packages
alongside it. All five must be developed explicitly — developing the umbrella alone will fail
to resolve.

```bash
julia --project -e 'using Pkg; Pkg.develop([
    PackageSpec(path = "../InfrastructureSystems.jl"),
    PackageSpec(path = "../PowerOpenAPIModels/PowerCoreOpenAPIModels.jl"),
    PackageSpec(path = "../PowerOpenAPIModels/PowerOperationsOpenAPIModels.jl"),
    PackageSpec(path = "../PowerOpenAPIModels/PowerInvestmentsOpenAPIModels.jl"),
    PackageSpec(path = "../PowerOpenAPIModels/PowerDynamicsOpenAPIModels.jl"),
    PackageSpec(path = "../PowerOpenAPIModels/PowerOpenAPIModels.jl"),
]); Pkg.instantiate()'

julia --project=test -e 'using Pkg; Pkg.develop(PackageSpec(path = ".")); Pkg.instantiate()'
```

Verify:

```bash
julia --project -e 'using PowerSystemsUpdater'
```

If `PowerOpenAPIModels` is regenerated from `SiennaSchemas` while you are working, re-run
`Pkg.instantiate()` — the generated types change and stale precompilation will produce
confusing `UndefVarError`s.

## Running the tests

```bash
julia --project=test test/runtests.jl
```

That runs the unit tier, which needs no data. Two further tiers are opt-in.

### Corpus tests

The PSY5 corpus lives under `data/`, which is **gitignored** — it is large and must be
generated locally. The tests are gated on `PSU_CORPUS`; without it they skip quietly, and with
it they fail loudly if the corpus is missing or incomplete.

```bash
# the systems the test suite references (fast)
julia --project=test/fixtures -e 'using Pkg; Pkg.instantiate()'
julia --project=test/fixtures test/fixtures/generate_fixtures.jl

# or the full corpus, every PowerSystemCaseBuilder system (slow, network-bound)
julia --project=scripts/psy5_case_generator -e 'using Pkg; Pkg.instantiate()'
julia --project=scripts/psy5_case_generator scripts/psy5_case_generator/psb_case_generator.jl

PSU_CORPUS=1 julia --project=test test/runtests.jl
```

Generation runs in its own environment pinned to `PowerSystems = "5"`. That is deliberate:
this package must never depend on PowerSystems, and the generator is the only thing here that
does.

### Python tier

Converted documents are also validated against the generated Python models. The tier is
skipped, loudly, when no interpreter is found.

```bash
python3 -m venv test/python/.venv
test/python/.venv/bin/pip install -r test/python/requirements.txt
```

Point `PSU_PYTHON` at an existing interpreter to use one instead. `power-openapi-models` is not
on PyPI, so `requirements.txt` installs it from GitHub — the environment must be able to reach
it.

## Development

Contributions to the development and enhancement of PowerSystemsUpdater is welcome. Please see [CONTRIBUTING.md](https://github.com/Sienna-Platform/PowerSystemsUpdater.jl/blob/main/CONTRIBUTING.md) for code contribution guidelines.

Run the formatter before submitting:

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
```

## License

PowerSystemsUpdater is released under a BSD 3-Clause
[license](https://github.com/Sienna-Platform/PowerSystemsUpdater.jl/blob/main/LICENSE),
copyright [QXT Energy](https://qxt.energy) and Alliance for Sustainable Energy, LLC.

Developed by QXT Energy and the U.S.
Department of Energy's National Laboratory of the Rockies (formerly known as NREL)
([NLR](https://www.nrel.gov/)) as part of the Sienna Platform.
