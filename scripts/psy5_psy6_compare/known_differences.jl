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
is renamed to `psy5_field` and its value passed through `to_psy5`, which gives the value PSY5
would have held. The values are then compared as usual, so a value with no PSY5 counterpart,
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
    return v -> get(table, v, v)
end

"""
PSY6's `HydroReservoir.head_to_volume_factor` is the `LinearFunctionData` PSY5 wrapped in a
`LinearCurve`. Rewrapping it compares the function data itself, and PSY5's `input_at_zero`
against `nothing`, since PSY6 has nowhere to keep it.
"""
function as_linear_curve(v::AbstractDict)
    if get(v, "__type__", nothing) != "LinearFunctionData"
        return v
    end
    return Dict{String, Any}(
        "__type__" => "LinearCurve",
        "function_data" => v,
        "input_at_zero" => nothing,
    )
end
as_linear_curve(v) = v

"""
PSY6's `operational_flow_limit` is a min/max pair per direction where PSY5's `flow_limits` held
one maximum per direction. With both minimums zero it is PSY5's `(from_to, to_from)`; a nonzero
minimum has no PSY5 counterpart and is left as is, so it fails.
"""
function as_flow_limits(v::AbstractDict)
    from_to = get(v, "from_to", nothing)
    to_from = get(v, "to_from", nothing)
    if isnothing(from_to) || isnothing(to_from) ||
       get(from_to, "min", nothing) != 0.0 || get(to_from, "min", nothing) != 0.0
        return v
    end
    return Dict{String, Any}("from_to" => from_to["max"], "to_from" => to_from["max"])
end
as_flow_limits(v) = v

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
Rewrites applied to every nested struct on the PSY6 side, innermost first, for changes that
are not tied to one component field.
"""
const NESTED_ALIGNMENTS = (curve_units_as_field, variable_cost_as_variable)

"""
An intended difference. `kind` is one of the `Difference` kinds in `compare.jl`; `psy5_type`
and `path` are glob patterns; `reason` is shown in the report.
"""
struct Expected
    kind::String
    psy5_type::String
    path::String
    reason::String
end

const EXPECTED = Expected[
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
