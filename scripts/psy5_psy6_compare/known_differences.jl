# The PSY5 -> PSY6 breaking changes the comparison accepts. Everything here is an intended
# difference between the data models; anything the comparison finds that is not covered here
# is reported as unexpected and fails the case.
#
# Written from the release's documented changes
# (docs/src/explanation/psy5_to_psy6_component_changes.md), deliberately NOT derived from
# PowerSystemsUpdater's own translation tables: an oracle built from the code under test would
# agree with every bug in it.
#
# Four kinds of entry. The first three reshape the PSY6 snapshot into PSY5's form before
# comparing, so the values are still checked; the last accepts a difference outright.
#   - `TYPE_MAPPINGS` say where a PSY5 component lives in PSY6 and how to line its PSY6 record
#     up with the PSY5 one, so the rest of the comparison is field-for-field.
#   - `FIELD_RULES` rename a component field and translate its value (`status` `"ONLINE"` is
#     PSY5's `true`).
#   - `NESTED_ALIGNMENTS` rewrite any nested struct, wherever it appears (cost curves).
#   - `EXPECTED` marks individual differences as intended, matched by kind, PSY5 type and
#     field path. `*` in any pattern matches any run of characters.

"""
Where a PSY5 type lives in PSY6.

  - `psy6_type`: the PSY6 type label, as a pattern: PSY6 parameterizes some types PSY5 did
    not, e.g. reserves by direction and units (`OnlineReserve{ReserveUp, NaturalUnit}`), so
    `OnlineReserve{ReserveUp, *}` matches any units while still checking the direction.
  - `flatten`: PSY6 fields holding a nested struct whose fields are lifted to the top level
    before comparing (e.g. a transformer's `circuit`).
  - `renames`: PSY6 field name => the PSY5 field name it is compared against.
"""
struct TypeMapping
    psy6_type::String
    flatten::Vector{String}
    renames::Dict{String, String}
end

function TypeMapping(
    psy6_type::String;
    flatten = String[],
    renames = Dict{String, String}(),
)
    return TypeMapping(psy6_type, flatten, renames)
end

const TWO_WINDING = TypeMapping(
    "TwoWindingTransformer";
    flatten = ["circuit"],
    renames = Dict("magnetizing_shunt" => "primary_shunt"),
)

const TYPE_MAPPINGS = Dict{String, TypeMapping}(
    "Transformer2W" => TWO_WINDING,
    "TapTransformer" => TWO_WINDING,
    "PhaseShiftingTransformer" => TWO_WINDING,
    # Three circuits rather than one, so no single flatten lines it up; its per-winding
    # fields are compared as missing/extra until a dedicated mapping is written.
    "Transformer3W" => TypeMapping("ThreeWindingTransformer"),
    # PSY6 folded MonitoredLine into Line; `flow_limits` is compared through `FIELD_RULES`.
    "MonitoredLine" => TypeMapping("Line"),
    "ConstantReserve{ReserveUp}" => TypeMapping("OnlineReserve{ReserveUp, *}"),
    "ConstantReserve{ReserveDown}" => TypeMapping("OnlineReserve{ReserveDown, *}"),
    "ConstantReserve{ReserveSymmetric}" =>
        TypeMapping("OnlineReserve{ReserveSymmetric, *}"),
    "VariableReserve{ReserveUp}" => TypeMapping("OnlineReserve{ReserveUp, *}"),
    "VariableReserve{ReserveDown}" => TypeMapping("OnlineReserve{ReserveDown, *}"),
    "VariableReserve{ReserveSymmetric}" =>
        TypeMapping("OnlineReserve{ReserveSymmetric, *}"),
    "ConstantReserveNonSpinning" => TypeMapping("OfflineReserve{*}"),
    "VariableReserveNonSpinning" => TypeMapping("OfflineReserve{*}"),
    "ConstantReserveGroup{ReserveUp}" => TypeMapping("GroupReserve{ReserveUp, *}"),
    "ConstantReserveGroup{ReserveDown}" => TypeMapping("GroupReserve{ReserveDown, *}"),
    "ConstantReserveGroup{ReserveSymmetric}" =>
        TypeMapping("GroupReserve{ReserveSymmetric, *}"),
)

type_mapping(psy5_type::AbstractString) =
    get(() -> TypeMapping(String(psy5_type)), TYPE_MAPPINGS, psy5_type)

"""
A component field whose name or value form changed in PSY6. On the PSY6 record, `psy6_field`
is renamed to `psy5_field` and its value passed through `to_psy5(value, system, record)`
(`system` is the snapshot's system header, for the base power; `record` the rest of the PSY6
record, for a field-specific base), which gives the value PSY5 would have held. The values are then compared as usual, so a value with no PSY5 counterpart,
or the wrong one, still fails. For each `psy6_field`, the first rule whose `psy5_type` glob
matches applies.
"""
struct FieldRule{F <: Function}
    psy5_type::String
    psy6_field::String
    psy5_field::String
    to_psy5::F
end

"""
A value translation: values in `pairs` map to their PSY5 counterpart, anything else passes
through unchanged and so fails the comparison.
"""
function value_map(pairs::Pair...)
    table = Dict{Any, Any}(pairs...)
    return (v, _...) -> get(table, v, v)
end

"""
PSY6's `HydroReservoir.head_to_volume_factor` is the `LinearFunctionData` PSY5 wrapped in a
`LinearCurve`. Rewrapping it compares the function data itself, and PSY5's `input_at_zero`
against `nothing`, since PSY6 has nowhere to keep it.
"""
function as_linear_curve(v::AbstractDict, _...)
    if get(v, "__type__", nothing) != "LinearFunctionData"
        return v
    end
    return Dict{String, Any}(
        "__type__" => "LinearCurve",
        "function_data" => v,
        "input_at_zero" => nothing,
    )
end
as_linear_curve(v, _...) = v

"""
PSY6's `operational_flow_limit` is a min/max pair per direction where PSY5's `flow_limits` held
one maximum per direction. With both minimums zero it is PSY5's `(from_to, to_from)`; a nonzero
minimum has no PSY5 counterpart and is left as is, so it fails.
"""
function as_flow_limits(v::AbstractDict, _...)
    from_to = get(v, "from_to", nothing)
    to_from = get(v, "to_from", nothing)
    if isnothing(from_to) || isnothing(to_from) ||
       get(from_to, "min", nothing) != 0.0 || get(to_from, "min", nothing) != 0.0
        return v
    end
    return Dict{String, Any}("from_to" => from_to["max"], "to_from" => to_from["max"])
end
as_flow_limits(v, _...) = v

"""A system-base per-unit power read back from PSY6, in the MW PSY5 stored."""
per_unit_to_mw(v::Real, system::AbstractDict, _...) = v * system["base_power"]

"""
An impedance PSY6 stores in ohms, as the per unit PSY5 stored on the system base power and the
voltage in `record[voltage_field]` (kV). Without a positive voltage the value is left as is.
"""
ohms_to_per_unit_on(voltage_field::AbstractString) =
    (v, system, record) -> _ohms_to_per_unit(v, system["base_power"], get(record, voltage_field, nothing))
_ohms_to_per_unit(v::Real, base_power::Real, kv::Real) =
    kv > 0 ? v / (kv^2 / base_power) : v
_ohms_to_per_unit(v, _, _) = v
per_unit_to_mw(v, _...) = v

"""The value unchanged; for a rule that only renames."""
same(v, _...) = v

"""
A phase-shift impedance correction curve read back in PSY6's radians, in the degrees PSY5
stored (PSS/E's convention).
"""
function radians_to_degrees_x(curve::AbstractDict, _...)
    points = get(curve, "points", nothing)
    if !(points isa AbstractVector)
        return curve
    end
    converted = Dict{String, Any}(curve)
    converted["points"] =
        [
            merge(Dict{String, Any}(p), Dict{String, Any}("x" => p["x"] * 180 / pi)) for
            p in points
        ]
    return converted
end
radians_to_degrees_x(curve, _...) = curve

const FIELD_RULES = FieldRule[
    # `status` became an `OperationalStates` enum. PSY5's pump status distinguished GEN from
    # PUMP; PSY6's ONLINE does not, so only OFF has a counterpart and a running pump fails.
    FieldRule("HydroPumpTurbine", "status", "status", value_map("OFFLINE" => "OFF")),
    FieldRule("*", "status", "status", value_map("ONLINE" => true, "OFFLINE" => false)),
    # `must_run` became one value of `commitment_mode`.
    FieldRule(
        "*",
        "commitment_mode",
        "must_run",
        value_map(
            "MUST_RUN" => true,
            "UNCOMMITTED" => false,
            "COMMITTED" => false,
            "SELF_SCHEDULED" => false,
            "RELIABILITY" => false,
        ),
    ),
    FieldRule(
        "HydroReservoir",
        "head_to_volume_factor",
        "head_to_volume_factor",
        as_linear_curve,
    ),
    FieldRule("MonitoredLine", "operational_flow_limit", "flow_limits", as_flow_limits),
    # LCC: PSY5's `power_mode` flag and one `transfer_setpoint` (MW or A) became
    # `control_mode` and one setpoint per mode; the MW setpoint is per unit in PSY6.
    FieldRule(
        "TwoTerminalLCCLine",
        "control_mode",
        "power_mode",
        value_map("POWER" => true, "CURRENT" => false),
    ),
    FieldRule(
        "TwoTerminalLCCLine",
        "power_transfer_setpoint",
        "transfer_setpoint",
        per_unit_to_mw,
    ),
    FieldRule("TwoTerminalLCCLine", "current_transfer_setpoint", "transfer_setpoint", same),
    # LCC impedances: PSY5 per unit on the system base power and the voltage of the circuit
    # they sit in (the DC line on `scheduled_dc_voltage`, each converter on its own AC base);
    # PSY6 in ohms, with no unit-aware getter.
    FieldRule("TwoTerminalLCCLine", "r", "r", ohms_to_per_unit_on("scheduled_dc_voltage")),
    FieldRule(
        "TwoTerminalLCCLine",
        "rectifier_rc",
        "rectifier_rc",
        ohms_to_per_unit_on("rectifier_base_voltage"),
    ),
    FieldRule(
        "TwoTerminalLCCLine",
        "rectifier_xc",
        "rectifier_xc",
        ohms_to_per_unit_on("rectifier_base_voltage"),
    ),
    FieldRule(
        "TwoTerminalLCCLine",
        "rectifier_capacitor_reactance",
        "rectifier_capacitor_reactance",
        ohms_to_per_unit_on("rectifier_base_voltage"),
    ),
    FieldRule(
        "TwoTerminalLCCLine",
        "inverter_rc",
        "inverter_rc",
        ohms_to_per_unit_on("inverter_base_voltage"),
    ),
    FieldRule(
        "TwoTerminalLCCLine",
        "inverter_xc",
        "inverter_xc",
        ohms_to_per_unit_on("inverter_base_voltage"),
    ),
    FieldRule(
        "TwoTerminalLCCLine",
        "inverter_capacitor_reactance",
        "inverter_capacitor_reactance",
        ohms_to_per_unit_on("inverter_base_voltage"),
    ),
    # VSC: each converter's single DC and AC setpoint became one field per controlled
    # quantity, selected by the control mode; all read back per unit, as PSY5 stored them.
    FieldRule("TwoTerminalVSCLine", "dc_power_setpoint_from", "dc_setpoint_from", same),
    FieldRule("TwoTerminalVSCLine", "dc_voltage_setpoint_from", "dc_setpoint_from", same),
    FieldRule("TwoTerminalVSCLine", "dc_power_setpoint_to", "dc_setpoint_to", same),
    FieldRule("TwoTerminalVSCLine", "dc_voltage_setpoint_to", "dc_setpoint_to", same),
    FieldRule("TwoTerminalVSCLine", "ac_voltage_setpoint_from", "ac_setpoint_from", same),
    FieldRule("TwoTerminalVSCLine", "power_factor_setpoint_from", "ac_setpoint_from", same),
    FieldRule("TwoTerminalVSCLine", "ac_voltage_setpoint_to", "ac_setpoint_to", same),
    FieldRule("TwoTerminalVSCLine", "power_factor_setpoint_to", "ac_setpoint_to", same),
    # "Regulates its own bus": remote bus 0 in PSY5, none in PSY6.
    FieldRule(
        "TwoTerminalVSCLine",
        "remote_bus_control_from",
        "remote_bus_control_from",
        value_map(nothing => 0),
    ),
    FieldRule(
        "TwoTerminalVSCLine",
        "remote_bus_control_to",
        "remote_bus_control_to",
        value_map(nothing => 0),
    ),
    # ImpedanceCorrectionData: one curve, interpreted by `transformer_control_mode`, became one
    # field per mode; a phase-shift curve's x axis went from degrees to radians.
    FieldRule(
        "ImpedanceCorrectionData",
        "tap_ratio_correction_curve",
        "impedance_correction_curve",
        same,
    ),
    FieldRule(
        "ImpedanceCorrectionData",
        "phase_angle_correction_curve",
        "impedance_correction_curve",
        radians_to_degrees_x,
    ),
]

"""
PSY6 unit-system type parameters, by the PSY5 `UnitSystem` name they replace.
"""
const UNIT_SYSTEM_NAMES = Dict(
    "NaturalUnit" => "NATURAL_UNITS",
    "ComponentBaseUnit" => "DEVICE_BASE",
    "SystemBaseUnit" => "SYSTEM_BASE",
)

"""
PSY6 moved a cost curve's `power_units` field into a type parameter:
`CostCurve{LinearCurve, NaturalUnit}` is PSY5's `CostCurve{LinearCurve}` with
`power_units = NATURAL_UNITS`.
"""
function curve_units_as_field(d::AbstractDict)
    m = match(r"^(CostCurve|FuelCurve)\{(.+), (\w+)\}$", string(get(d, "__type__", "")))
    if isnothing(m) || !haskey(UNIT_SYSTEM_NAMES, m[3])
        return d
    end
    aligned = Dict{String, Any}(d)
    aligned["__type__"] = "$(m[1]){$(m[2])}"
    aligned["power_units"] = UNIT_SYSTEM_NAMES[m[3]]
    return aligned
end

"""
PSY6 renamed every operating cost's `variable` to `variable_operation_cost`.
"""
function variable_cost_as_variable(d::AbstractDict)
    if !haskey(d, "variable_operation_cost") ||
       !occursin("Cost", string(get(d, "__type__", "")))
        return d
    end
    aligned = Dict{String, Any}(k => v for (k, v) in d if k != "variable_operation_cost")
    aligned["variable"] = d["variable_operation_cost"]
    return aligned
end

"""
PSY6 wraps an HVDC line's loss curve (`loss`, `converter_loss_from`/`_to`) in a `LossCurve`
whose type parameter is its unit system: `LossCurve{LinearCurve, NaturalUnit}` holds PSY5's
`LinearCurve` as `value_curve`. Compared by the wrapped curve, as `head_to_volume_factor` is.
"""
function loss_curve_as_value_curve(d::AbstractDict)
    if !startswith(string(get(d, "__type__", "")), "LossCurve{") ||
       !haskey(d, "value_curve")
        return d
    end
    return d["value_curve"]
end

"""
PSY6's `ZERO_OFFER_CURVE` (`CostCurve(PiecewiseIncrementalCurve(0.0, [0.0, 0.0], [0.0]))`), as
it reads back after `curve_units_as_field`: PSY6's spelling of an offer curve PSY5 left
`nothing` ("not offered").
"""
function is_zero_offer_curve(d::AbstractDict)
    get(d, "__type__", nothing) == "CostCurve{PiecewiseIncrementalCurve}" || return false
    curve = something(get(d, "value_curve", nothing), Dict())
    data = something(get(curve, "function_data", nothing), Dict())
    vom = something(get(d, "vom_cost", nothing), Dict())
    vom_data = something(get(vom, "function_data", nothing), Dict())
    return get(curve, "initial_input", nothing) == 0.0 &&
           get(data, "x_coords", nothing) == [0.0, 0.0] &&
           get(data, "y_coords", nothing) == [0.0] &&
           get(vom_data, "constant_term", nothing) == 0.0 &&
           get(vom_data, "proportional_term", nothing) == 0.0
end
is_zero_offer_curve(_) = false

"""
`ImportExportCost{NaturalUnit}` is PSY5's `ImportExportCost`: the unit system became a type
parameter, which PSY5 never recorded (like the cost curves in 14). An offer curve PSY5 left
`nothing` comes back as `ZERO_OFFER_CURVE`, and is compared as `nothing`.
"""
function import_export_cost_as_psy5(d::AbstractDict)
    m = match(r"^ImportExportCost\{(\w+)\}$", string(get(d, "__type__", "")))
    if isnothing(m) || !haskey(UNIT_SYSTEM_NAMES, m[1])
        return d
    end
    aligned = Dict{String, Any}(d)
    aligned["__type__"] = "ImportExportCost"
    for field in ("import_offer_curves", "export_offer_curves")
        if is_zero_offer_curve(get(d, field, nothing))
            aligned[field] = nothing
        end
    end
    return aligned
end

"""
PSY5's `FuelCurve.fuel_cost` held either a price or a time series key; PSY6 keeps the key in
`fuel_cost_time_series`. The PSY6 snapshot records that key as the series it names, in PSY5's
key shape, so it is compared as PSY5's `fuel_cost`.
"""
function fuel_cost_series_as_fuel_cost(d::AbstractDict)
    if !startswith(string(get(d, "__type__", "")), "FuelCurve") ||
       isnothing(get(d, "fuel_cost_time_series", nothing))
        return d
    end
    aligned = Dict{String, Any}(k => v for (k, v) in d if k != "fuel_cost_time_series")
    aligned["fuel_cost"] = d["fuel_cost_time_series"]
    return aligned
end

"""
Rewrites applied to every nested struct on the PSY6 side, innermost first, for changes that
are not tied to one component field.
"""
const NESTED_ALIGNMENTS = (
    curve_units_as_field,
    variable_cost_as_variable,
    loss_curve_as_value_curve,
    import_export_cost_as_psy5,
    fuel_cost_series_as_fuel_cost,
)

"""
An intended difference. `kind` is one of the `Difference` kinds in `compare.jl`; `psy5_type`
and `path` are glob patterns; `reason` is shown in the report. `when(psy5, psy6)` narrows the
match to particular values (default: any).
"""
struct Expected{F <: Function}
    kind::String
    psy5_type::String
    path::String
    reason::String
    when::F
end

Expected(kind, psy5_type, path, reason) =
    Expected(kind, psy5_type, path, reason, (_, _) -> true)

"""
A non-physical PSY5 value (≤ 0) the updater left unset and reported (INVALID VALUES DROPPED).
"""
dropped_non_physical(psy5::Real, psy6) = psy5 <= 0 && isnothing(psy6)
dropped_non_physical(_, _) = false

const EXPECTED = Expected[
    # Dynamic models: the 0.2 schema has none. The updater skips them, keeps the static
    # device, drops its link, and reports both (UNMAPPED TYPES, DYNAMIC MODELS DROPPED).
    # Not `DynamicBranch`: it embeds a whole static `Line`, so dropping it loses the line.
    Expected(
        "missing_component",
        "DynamicGenerator*",
        "",
        "dynamic models are not in the 0.2 schema; reported as dropped",
    ),
    Expected(
        "missing_component",
        "DynamicInverter*",
        "",
        "dynamic models are not in the 0.2 schema; reported as dropped",
    ),
    Expected(
        "value",
        "*",
        "dynamic_injector",
        "dynamic model dropped (no 0.2 schema home); static device kept, link reported",
    ),
    # An attribute's monitored components are a set of UUIDs in PSY5 and of integer ids in PSY6:
    # the identity change, which the snapshot cannot follow into a set.
    Expected(
        "value",
        "SupplementalAttribute",
        "*monitored_components.__type__",
        "component identity moves from UUIDs to integer ids",
    ),
    # Transformers
    Expected(
        "missing_field",
        "Transformer2W",
        "winding_group_number",
        "PSY6 drops WindingGroupNumber; the angle survives as circuit α",
    ),
    Expected(
        "missing_field",
        "TapTransformer",
        "winding_group_number",
        "PSY6 drops WindingGroupNumber; the angle survives as circuit α",
    ),
    Expected(
        "missing_field",
        "TapTransformer",
        "tap_limits",
        "dropped in PSY6 without a replacement",
    ),
    Expected(
        "missing_field",
        "TapTransformer",
        "voltage_setpoint",
        "dropped in PSY6 without a replacement",
    ),
    Expected(
        "missing_field",
        "Transformer3W",
        "available",
        "Transformer3W availability is per-circuit in PSY6",
    ),
    Expected(
        "missing_field",
        "Transformer3W",
        "rating",
        "Transformer3W rating is per-circuit in PSY6",
    ),
    Expected(
        "value",
        "*Transformer*",
        "base_voltage_*",
        "non-physical winding base voltage (≤ 0) left unset; reported as dropped",
        dropped_non_physical,
    ),
]

"""
Differences that are recorded and reported but never fail a case:

  - `extra_field`: a field PSY6 added with a default is new information, not a change to
    anything PSY5 held. A field that was *renamed* still fails, because its PSY5 side shows up
    as `missing_field`.
  - `unreadable_both`: the snapshot could read the value on neither side (e.g. `horizon` of a
    `SingleTimeSeries`), so there is nothing to compare.
  - `moved_to_ext`: a PSY5 field with no PSY6 field, which the updater kept in the component's
    `ext["psy5_unmapped"]`. Not lost, but no longer a field, so it is listed. Its value is as
    PSY5 stored it, not through a getter, so it is not compared.
"""
const INFORMATIONAL_KINDS = Set(["extra_field", "unreadable_both", "moved_to_ext"])

"""
Relative and absolute tolerance for numeric values. Loose enough for per-unit conversions done
in a different order on each side, tight enough to catch a wrong base.
"""
const RTOL = 1e-8
const ATOL = 1e-10
