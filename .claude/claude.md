# PowerSystemsUpdater.jl

Upgrades PowerSystems JSON files from the PSY5 specification to the PSY6 OpenAPI
JSON document, producing PSY6-compatible cases.

- **Depends on IS4** (`InfrastructureSystems.jl`, psy6 line) for time series and
  other object conversions between the PSY5 and PSY6 data models.
- **No PSY6 dependency.** Write output cases using the serde code in
  `PowerOpenAPIModels.jl`, not `PowerSystems.jl` (PSY6).
- **Test against PSY6.** Tests may load produced cases with PSY6 to confirm
  compatibility, but PSY6 stays a test-only dependency, never a package dependency.
- **Load PSY5 JSON with `JSON.jl`.** Read source PSY5 case files with `JSON.jl`,
  not PSY5 itself.
- **Reference test data lives in `data/`.** PSY5 sample cases and their expected
  PSY6 outputs for tests belong in the `data` folder.

**General Sienna Programming Practices:** For information on performance requirements, code conventions, documentation practices, and contribution workflows that apply across all Sienna packages, see [Sienna.md](Sienna.md).
