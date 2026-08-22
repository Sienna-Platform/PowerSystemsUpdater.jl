# What changes between PSY5 and PSY6

Everything a serialized PSY5 component meets on the way to a PSY6 `SystemDocument`.
Derived from converting 104 real systems; each row is something the converter had to handle,
not something the schema merely permits.

## Identity and references

|            | PSY5                         | PSY6                                                               |
|:---------- |:---------------------------- |:------------------------------------------------------------------ |
| Identity   | `internal.uuid.value` (UUID) | `id`, an integer                                                   |
| Reference  | `{"value": "<uuid>"}`        | the target's integer `id`                                          |
| Uniqueness | per system                   | **across all types**, and disjoint from supplemental-attribute ids |

A bus `number` is not an id. Nothing in PSY6 validates ordinary component references
(`bus`, `arc`), so a converter must guarantee them itself — `validate_document` checks only
association, owner and `ext` keys.

## Units

PSY5 offers `SYSTEM_BASE`, `DEVICE_BASE`, `NATURAL_UNITS`. **PSY6 drops `SYSTEM_BASE`.**

Stored PSY5 values are already device base — `_get_multiplier(…, ::Val{DEVICE_BASE}, ::Any) = 1.0`,
with the other two derived at access time. So no rescaling is needed to emit `DEVICE_BASE`.

PSY6 now records `base_power` on `Line`, `MonitoredLine`, and ten other components whose base
is the *system* base (`Area`, `LoadZone`, `FixedAdmittance`, `AreaInterchange`,
`DiscreteControlledACBranch`, `GenericArcImpedance`, `TransmissionInterface`, and the three
`TwoTerminal*Line` HVDC types — see the `BasePowerKind` trait in PowerSystems'
`src/models/components.jl`),
recorded per component *"in lieu of a system-level table"*. `ACBus`, `Arc`, `AGC`, and `DCBus`
still declare none; their base remains implicit on the system base.

## Type parameters become fields

PSY5 encodes variation in the type parameter; PSY6 in a property, often with a new vocabulary.

| PSY5                           | PSY6                                          |
|:------------------------------ |:--------------------------------------------- |
| `ConstantReserve{ReserveUp}`   | `OnlineReserve`, `reserve_direction = "UP"`   |
| `VariableReserve{ReserveDown}` | `OnlineReserve`, `reserve_direction = "DOWN"` |

`ReserveUp` → `"UP"` is a rename, not a passthrough. `ConstantReserve` and `VariableReserve`
have identical PSY5 field sets — the distinction is carried by whether a `requirement` time
series is attached, not by any field.

Reserve consolidation: spinning → `OnlineReserve`, non-spinning → `OfflineReserve`,
`ConstantReserveGroup` → `GroupReserve`.

## Transformers — the largest restructuring

PSY6 has no `Transformer2W`, `TapTransformer`, `PhaseShiftingTransformer` or `Transformer3W`.
Electrical data moves into a separate `TransformerCircuit` component, so one PSY5 component
becomes several.

| PSY5                                                          | PSY6                                               |
|:------------------------------------------------------------- |:-------------------------------------------------- |
| `Transformer2W`, `TapTransformer`, `PhaseShiftingTransformer` | `TwoWindingTransformer` + 1 `TransformerCircuit`   |
| `Transformer3W`                                               | `ThreeWindingTransformer` + 3 `TransformerCircuit` |

Consequences worth knowing:

  - **`WindingGroupNumber` is gone**; only the angle survives, as `TransformerCircuit.alpha` in
    radians. The enum is sparse and sign-inverted — `GROUP_1` is **−30°**, not +30 — so it maps
    through a literal table, never `n × 30°`. `UNDEFINED` (a third of real transformers) means
    "not specified" and takes the schema default of `0.0`.
  - **`PhaseShiftingTransformer.α` is already radians** and copies verbatim. It never coexists
    with a winding group, so the two sources are never summed.
  - **The 1-3 winding pair becomes 3-1**: `r_13`/`x_13`/`base_power_13` → `r_31`/`x_31`/`base_power_31`.
    The 1-2 and 2-3 pairs keep their names. A silent-corruption trap.
  - **Availability and rating are circuit-level.** `Transformer3W`'s top-level `available` and
    `rating` have no PSY6 home; each circuit carries its own.
  - **`g`/`b` become one `magnetizing_shunt`** (`ComplexNumber`). On a three-winding transformer
    it sits star-bus-to-ground, so `shunt_location = "STAR"` — unlike the two-winding case,
    whose `primary_shunt` genuinely is primary-side and takes the `"PRIMARY"` default.

## Discriminated unions

PSY5 tags every nested object with `__metadata__.type`. PSY6 uses JSON-Schema `oneOf` with an
explicit discriminator **property that PSY5 has no field for**. It must be synthesized, and
it nests — a `CostCurve` contains a `ValueCurve` containing `FunctionData`, each needing its own.

| Union                                                | Property             | Example                             |
|:---------------------------------------------------- |:-------------------- |:----------------------------------- |
| `ProductionVariableCostCurve`                        | `variable_cost_type` | `CostCurve` → `COST`                |
| `ValueCurve`                                         | `curve_type`         | `InputOutputCurve` → `INPUT_OUTPUT` |
| `FunctionData`                                       | `function_type`      | `LinearFunctionData` → `LINEAR`     |
| `GenericOperationCost`, `HydroStorageGenerationCost` | `cost_type`          | `ThermalGenerationCost` → `THERMAL` |
| `TwoTerminalLoss`                                    | `curve_type`         |                                     |

One branch carries no tag at all: `ThermalGenerationCost`'s `StartUpStages` is identified by
its `{hot, warm, cold}` key set.

Narrowed unions differ from the general one. `IncrementalCurve` and `AverageRateCurve` accept
only `{LINEAR, PIECEWISE_STEP}`, while `InputOutputCurve` accepts `{LINEAR, PIECEWISE_LINEAR, QUADRATIC}` — matching the Julia type bounds in `InfrastructureSystems`.

## Time series

The sidecar is rewritten, not copied. PSY5 keys one HDF5 group per time series UUID under
`/time_series` and embeds its association table as a SQLite blob in a second dataset. PSY6
uses InfraStore, which addresses every array by its SHA-256 content hash and keeps the
associations in a sibling catalog file:

|                | PSY5                          | PSY6 (InfraStore)                        |
|:-------------- |:----------------------------- |:---------------------------------------- |
| Array identity | the time series UUID          | the array's SHA-256 content hash         |
| Array location | `/time_series/<uuid>/data`    | one packed HDF5 dataset per array group  |
| Associations   | a SQLite blob inside the HDF5 | `time_series.h5.sqlite`, beside the HDF5 |
| Duplicate data | one group per series          | de-duplicated by content hash            |

A byte copy would therefore produce a bundle whose arrays no reader can resolve: the UUID
that keyed them no longer exists anywhere in the stack, and there is no catalog to say which
association owns which array. So `convert_time_series` decodes each array and re-adds it
through `InfraStore.jl`, which writes both halves. **The `.h5` and its `.sqlite` are one
artifact and must travel together.**

PSY6's importer adopts that catalog as the System's own time series store rather than
replaying the document's `time_series_associations`, so the catalog is the copy that is
actually read. Both are written, and both carry the same declarations.

Three element layouts and one time series type make the crossing:

| PSY5                                              | PSY6                                       |
|:------------------------------------------------- |:------------------------------------------ |
| `CONSTANT` scalars                                | unchanged; InfraStore derives the dtype    |
| `PiecewiseStepData`, NaN-padded `(n, 2)` matrices | one self-describing `piecewise_step` row   |
| `SingleTimeSeries`, `Deterministic`               | the same types, same array shapes          |
| `DeterministicSingleTimeSeries`                   | derived by `transform_single_time_series!` |

A derived forecast stores no array of its own in PSY6 — it re-describes the
`SingleTimeSeries` it came from. InfraStore derives from every series at a resolution or from
none, so a sidecar whose derived rows cover only some of them aborts rather than gaining or
losing forecasts. Every other layout and type (`PiecewiseLinearData`, `Probabilistic`,
`Scenarios`) errors: the two stores agree on nothing but plain scalars, and a `Probabilistic`
association row carries no percentiles to rebuild one from.

The association metadata moves too. PSY5 embeds a whole SQLite database inside the HDF5; PSY6
puts the rows in the document as `time_series_associations`, with `time_series_storage_file`
naming the sidecar by basename. Four columns do not map straight across:

| PSY5                        | PSY6                            |
|:--------------------------- |:------------------------------- |
| `owner_uuid`                | `owner_id`, an integer          |
| `time_series_uuid`          | dropped with UUID identity      |
| `metadata_uuid`             | dropped with UUID identity      |
| `scaling_factor_multiplier` | `unit_system` + `quantity_kind` |

PSY5 stored a scaled series as a fraction and named an accessor to multiply it by on
retrieval. PSY6 rescales nothing, so the multiplier's meaning is re-expressed: the values are
per-unit on the owner's own base, which is `unit_system = DEVICE_BASE`, and the accessor's
physical quantity becomes `quantity_kind` (a `Core/units.json` vocabulary name).

The reservoir accessors — `get_storage_capacity`, `get_storage_target`, `get_inflow` — get a
basis but no `quantity_kind`: a reservoir level is an energy, a volume, or a head depending on
the owner's `level_data_type`, which an association row does not carry. Those are counted in
the conversion report as unmapped `quantity_kind` rather than guessed at.

The document's `element_type` and `application_data` are left unset. Both describe the stored
array, and PSY6 reads an array's description from the catalog — where `element_type` *is*
written — so filling them into the document too would add a second copy with no reader.

## Document structure

|                | PSY5                                          | PSY6                                                              |
|:-------------- |:--------------------------------------------- |:----------------------------------------------------------------- |
| Components     | one flat array, `__metadata__`-tagged         | map of type name → array                                          |
| Subcomponents  | `data.masked_components` (HybridSystem parts) | ordinary components, referenced by id                             |
| Attributes     | `supplemental_attribute_manager`              | `supplemental_attributes` + `supplemental_attribute_associations` |
| Version marker | `data_format_version: "5.0.0"`                | none — only `unit_system` is self-describing                      |

## Fields with no PSY6 home

Dropped by design: `services` (schema convention), `WindingGroupNumber` (superseded by
`alpha`), `Transformer3W.available` / `.rating` (now circuit-level).

Dropped without a stated replacement, and worth reporting when encountered:
`TapTransformer.tap_limits`, `TapTransformer.voltage_setpoint`.

## What PSY6 cannot yet express

**Time-series-valued fields.** PSY5 embeds a `ForecastKey` or `StaticTimeSeriesKey` directly in
a value field — `FuelCurve.fuel_cost` and `MarketBidCost.incremental_offer_curves` in the
corpus. PSY6 types these as scalars or curves, with no representation for "this comes from a
time series."

**Scalar operating costs, resolved.** `MarketBidCost.shut_down` and `no_load_cost` are typed as
a concrete `InputOutputCurve`; PSY5 writes a bare `Float64`. The schema now sanctions this: its
`description` documents the "legacy scalar promotion" and its `default` gives the exact
`InputOutputCurve` shape the converter builds (`LinearFunctionData` with `constant_term = s`,
`proportional_term = 0`) — see `Core/common.json`. The converter promotes accordingly.
