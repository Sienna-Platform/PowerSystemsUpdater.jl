# PSY5 → PSY6 Updater — Open Items

**Date:** 2026-08-06 (session end)

The design and implementation plans this work was executed from have been deleted — the code
is the record now, and `docs/src/explanation/psy5_to_psy6_component_changes.md` documents
every PSY5→PSY6 modelling difference the converter handles. This file is only what is *left*.

State across the three repos at handoff:

| Repo | Branch / HEAD | Working tree |
|---|---|---|
| `PowerSystemsUpdater.jl` | `feature/psy5-to-psy6-updater` @ `4a0c151` | **11 files uncommitted** |
| `SiennaSchemas` | `jd/ptdp_pffp_integration_changes` @ `490a83c` | clean |
| `PowerOpenAPIModels` | — | **219 files uncommitted** (regenerated from `490a83c`) |

Last verified numbers, before the schema regeneration: **487/487 tests, 103/103 write,
97/103 Julia round-trip.** These move once the schema settles; re-measure before trusting.

---

## 1. BLOCKER — `operation_cost` unions generate broken code

Ten `operation_cost` fields were widened to a `oneOf` admitting `MarketBidCost`. The
discriminator `mapping` uses **relative cross-file paths**, which openapi-generator cannot
resolve. Regenerating from `490a83c` produces, in six union files:

```julia
if discriminator == "MARKET_BID"
    return eval(Base.Meta.parse("ERRORUNKNOWN"))
```

Affected: `ThermalStandardOperationCost`, `ThermalMultiStartOperationCost`,
`EnergyReservoirStorageOperationCost`, `HydroDispatchOperationCost`,
`InterruptiblePowerLoadOperationCost`, `RenewableDispatchOperationCost` — six, not ten,
because the Hydro trio and the Load trio each collapse to one shared union. Plus a spurious
`model_MarketBidCost1.jl`.

`read_document` then fails with `UndefVarError` on any component routed through those
resolvers. **This is authoring error introduced in this effort, now committed at `490a83c`.**

**Fix.** Every discriminator that works today is same-file, inside `Core/common.json`. Define
five named unions there — where both members already live, so refs are same-file — and `$ref`
them from the component files. This is exactly how `ValueCurve`, `FunctionData` and
`ProductionVariableCostCurve` already work.

| Union to add | Members |
|---|---|
| `ThermalOperationCost` | `ThermalGenerationCost` + `MarketBidCost` |
| `HydroOperationCost` | `HydroGenerationCost` + `MarketBidCost` |
| `LoadOperationCost` | `LoadCost` + `MarketBidCost` |
| `StorageOperationCost` | `StorageCost` + `MarketBidCost` |
| `RenewableOperationCost` | `RenewableGenerationCost` + `MarketBidCost` |

All six cost types already carry a distinct `cost_type` const (`THERMAL`, `HYDRO_GEN`, `LOAD`,
`STORAGE`, `RENEWABLE`, `MARKET_BID`), so the discriminator needs no new fields.

Then regenerate and confirm no `ERRORUNKNOWN` and no `MarketBidCost1`.

**Two schema fixes from this effort are good and need no rework:** `AverageRateCurve`
narrowed to `{LINEAR, PIECEWISE_STEP}` (its separate union file correctly collapsed), and
`FuelCurve.startup_fuel_offtake` added.

## 2. Regeneration is uncommitted and partially broken

`PowerOpenAPIModels` has 219 uncommitted files stamped `490a83c`. Do not commit until item 1
lands, or the broken resolvers enter history. Regenerate with:

```bash
docker build -t power-codegen .
make generate-docker SCHEMA_DIR=../SiennaSchemas CODEGEN_IMAGE=power-codegen
```

The published `ghcr.io/sienna-platform/power-codegen:latest` requires auth; the local build
works.

## 3. Uncommitted work in this repo

11 files, all reviewed, none committed:

- **Docs** — `docs/src/explanation/psy5_to_psy6_component_changes.md` + `docs/make.jl` wiring.
- **Comment cleanup** — corpus counts, system names and cross-repo line numbers stripped from
  `src/` docstrings.
- **Two converter changes**, implemented and tested but *not* re-measured since:
  - `MarketBidCost.shut_down`/`no_load_cost`: a bare PSY5 `Float64` becomes
    `InputOutputCurve(LinearFunctionData(constant_term = s, proportional_term = 0.0))`.
  - Embedded time-series pointers now throw `Psy5FormatError` instead of converting.

The second deliberately makes ~9 systems fail conversion. That is intended, but it means
`KNOWN_CONVERSION_GAPS` and the corpus counts need re-measuring once item 1 is fixed.

## 4. Parked from the final whole-branch review

**Cross-component ordering (Critical, dormant).** `lookup_id` now throws on a skipped uuid,
which closed the depth and same-uuid cases. It did **not** close processing order:
`build_document` makes one forward pass in raw JSON order, so if A precedes B and B is later
skipped, A's lookup fires before B is marked and A ships with a live id to a component that
never lands. Reproduced: `ACBus(id=1, area=2)` with no id 2 in the document and
`validate_document` passing.

Cannot fire while `KNOWN_GAPS` is empty and no type is skipped. The fix is a fixpoint or
two-pass skip resolution — a design change, not a patch.

**Nested unmapped fields are recorded but not omitted (Important).** `build_kwargs` records
*and* omits; `translate_value` only records, so the field still ships. Because pydantic drops
unknown keys on re-dump, the repo's own recursive drop-diff then reports ~1096 expected
errors, burying real regressions. Fix is mechanical: delete flagged keys before returning.

## 5. Schema gaps found, not yet addressed

**Time-series-valued fields.** PSY5 embeds a `ForecastKey`/`StaticTimeSeriesKey` directly in a
value field; PSY6 has no representation for one. Measured: `FuelCurve.fuel_cost` (6),
`MarketBidCost.incremental_offer_curves` (8). The converter now errors loudly; PSY6 needs a
design decision about how time-series-valued fields are expressed at all.

**`MarketBidCost` scalar costs.** `shut_down`/`no_load_cost` are `$ref: InputOutputCurve` with
no `oneOf` admitting a number, but PSY5 writes `0.0`. The object under the schema's `default`
applies only when the field is *absent* and does not sanction a scalar. The converter now
promotes it; whether the schema should also admit a scalar is open.

## 6. Julia / Python binding drift

At session start the two bindings were generated from different schema revisions — Julia
`89f078c-dirty`, Python `none`, SiennaSchemas HEAD `db4b48b`. Julia has since been regenerated
to `490a83c`; **Python has not**. Until `power-openapi-models` is regenerated from the same
commit, the Python tier's verdict is not trustworthy — most of its rejections are drift, not
translator defects. Tracked in `KNOWN_PYTHON_SCHEMA_DRIFT`.

## 7. CI runs none of the headline gates

`data/` is gitignored and no workflow generates it. The corpus, round-trip and Python testsets
are gated on `PSU_CORPUS`; **no workflow sets it**, so CI proves only the corpus-free unit
tier. This is honest rather than silently green — the gate fails loudly when `PSU_CORPUS` is
set but the corpus is absent or incomplete — but it means the headline numbers are local-only.

Decide how CI gets a corpus: run `test/fixtures/generate_fixtures.jl` (slow, network-bound) in
a scheduled job, or publish a fixture archive.

## 8. Deferred minors

- SQLite handle closed outside `try`/`finally`, so a throwing query leaks it.
- Round-trip failure messages truncated to the first line; conversion failures keep the full text.
- The corpus is converted twice per run (~206 conversions) because two testsets each sweep it.
- The drift canary asserts PSY6 fieldnames only, never the PSY5 side, so a PSY5-side rename
  passes clean. Item 4's nested-filtering fix would supersede it.
- `PCOM.reserve_ids!` is called three times but nothing in this package calls `next_id!`.
