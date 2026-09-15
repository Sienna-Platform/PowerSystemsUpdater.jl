# The units transformation

## What gets transformed

A PSY6 `SystemDocument` carries no document-level unit system and no document-level base
power. Every component blob is self-interpretable: it carries its own `base_power`, and any
power-bearing field on it carries a required `power_units` declaration naming the basis that
field's number is expressed in. A consumer holding one component in isolation — no document,
no sibling components — can still read every value on it correctly.

This package writes that per-blob declaration. Converting a PSY5 `System` JSON bundle, it
stamps `power_units` on every PSY6 model that declares the field.

## Why every stamp reads `COMPONENT_BASE`

PSY5 already stores its numbers per-unit on a base — the component's own `base_power` when
it declares one, the system base otherwise (`base_power_for` in `src/base_power.jl` supplies
that fallback). The updater's job is to say what a number already is, not to change what it
is. Every `power_units` this package writes is `"COMPONENT_BASE"`, and no value is ever
rescaled: a PSY5 `0.8` reaches the PSY6 blob as `0.8`. The stamp is a label, not a
computation.

## Vocabulary

PSY6's basis vocabulary has exactly two members: `COMPONENT_BASE` and `NATURAL_UNITS`. There
is no `DEVICE_BASE` and no system-wide basis. A value historically expressed on a shared
system base does not get a third label — it gets `COMPONENT_BASE`, with that shared base
recorded as the blob's own `base_power`. "Component" and "system" are both just numbers in
`base_power`; the only basis word left in the schema is `COMPONENT_BASE`.

## Where the stamp is written

Two paths write `power_units`, both before any value in the model is touched:

  - **The generic path** (`direct_translate` in `src/translate/dispatch.jl`): for any PSY6
    type that declares a `power_units` field, the translator adds
    `power_units = "COMPONENT_BASE"` to the constructor kwargs alongside `base_power`, whatever
    the PSY5 type being converted.
  - **The transformer paths** (`src/translate/transformers.jl`): `TransformerCircuit` is built
    by hand for both two-winding transformers (`_build_circuit`) and each winding of a
    three-winding transformer (`_winding_circuit`), so each stamps `power_units = "COMPONENT_BASE"` explicitly rather than through the generic dispatch.

## The cost-member rename

PSY5 spells the variable cost field `variable` on `ThermalGenerationCost`,
`HydroGenerationCost`, `RenewableGenerationCost`, and `LoadCost`; PSY6 requires
`variable_operation_cost`. `_rename_variable_operation_cost` in `src/translate/fields.jl`
renames the key before the recursive field copy (`translate_value`) walks the value, so the
renamed payload lands in the required PSY6 member instead of being recorded as an unmapped
PSY5 field with the required member left absent.

## What else governs a field's units

Not every field reads `power_units`. A cost curve nested inside a component (a `CostCurve` or
`FuelCurve`) carries its own `power_units`, resolved against the *owning component's*
`base_power` — not a fresh basis of its own. Other quantities use other discriminators
entirely: `parameter_units`, `energy_units`, and the rest of the `UnitSystem` family, each
scoped to the field it annotates. A field with a fixed `x-unit` (for example `frequency` in
Hz) needs no basis at all — it is already in its one physical unit. Which discriminator
governs which field, and how to resolve a `COMPONENT_BASE` reading once you have found it, are
schema questions; see [Reference: the units page](#reference-the-units-page) below.

## Worked example

Input, a PSY5 `ThermalStandard` (abbreviated — a real PSY5 blob carries more fields than
shown here):

```json
{
  "__metadata__": {"type": "ThermalStandard"},
  "internal": {"uuid": {"value": "uuid-gen1"}},
  "name": "gen1",
  "base_power": 150.0,
  "active_power": 0.8
}
```

Output, the PSY6 blob `translate_component` produces for it (abbreviated the same way):

```json
{
  "id": 1,
  "name": "gen1",
  "base_power": 150.0,
  "power_units": "COMPONENT_BASE",
  "active_power": 0.8
}
```

`active_power` is untouched — `0.8` in, `0.8` out — because it was already per-unit on
`base_power = 150.0`; the only new thing is the `power_units` label declaring that basis.
Verified by calling `PowerSystemsUpdater.translate_component` on this input directly against
the code on this branch.

## Reference: the units page

[SiennaSchemas' units page](https://sienna-platform.github.io/SiennaSchemas/units/) is the
authoritative reading guide: the decision procedure for resolving any field's unit from its
discriminator and basis, and the full `UnitSystem` vocabulary this page only summarizes. (The
site is pre-release and may 404 today; the URL is the permanent target, the same convention
SiennaGridDB's README uses for its own units section.) Adding a new unit or annotation is a
schema question, not a converter one — see `docs/UNIT_ANNOTATIONS.md` in the SiennaSchemas
repository for the authoring rules.
