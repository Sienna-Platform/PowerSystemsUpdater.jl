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
  - `windings`: PSY6 fields holding one nested circuit per winding => the winding's name in
    PSY5's field names. Each circuit field is lifted under its PSY5 per-winding name
    (`WINDING_FIELDS`, with `{w}` replaced by the winding), or as `<field>@<circuit>` when PSY5
    has no counterpart, so it shows as a new PSY6 field.
  - `reshape`: a final `record -> record` step for a change no rename expresses (one PSY6
    field that was two in PSY5).
"""
struct TypeMapping{F <: Function}
    psy6_type::String
    flatten::Vector{String}
    renames::Dict{String, String}
    windings::Dict{String, String}
    reshape::F
end

function TypeMapping(
    psy6_type::String;
    flatten = String[],
    renames = Dict{String, String}(),
    windings = Dict{String, String}(),
    reshape = identity,
)
    return TypeMapping(psy6_type, flatten, renames, windings, reshape)
end

"""
A three-winding transformer's circuit fields => the PSY5 per-winding field each is compared
against, `{w}` standing for `primary`/`secondary`/`tertiary`. PSY5 kept every winding's data
flat on the transformer; PSY6 moved it into one `TransformerCircuit` per winding. A
`Transformer3W` has no `α_{w}` (its angle came from `{w}_group_number`, which PSY6 drops), so
there the circuit's `α` is a new field; a `PhaseShiftingTransformer3W` compares it.
"""
const WINDING_FIELDS = Dict(
    "arc" => "{w}_star_arc",
    "tap" => "{w}_turns_ratio",
    "α" => "α_{w}",
    "alpha" => "α_{w}",
    "r" => "r_{w}",
    "x" => "x_{w}",
    "rating" => "rating_{w}",
    "available" => "available_{w}",
    "active_power_flow" => "active_power_flow_{w}",
    "reactive_power_flow" => "reactive_power_flow_{w}",
    "control_objective" => "control_objective_{w}",
    "base_voltage_primary" => "base_voltage_{w}",
)

"""
PSY6's three-winding `magnetizing_shunt` (a complex number, star bus to ground) as the `g`/`b`
pair PSY5 held.
"""
split_magnetizing_shunt(record::Dict{String, Any}) =
    _split_shunt!(record, get(record, "magnetizing_shunt", nothing))

function _split_shunt!(record::Dict{String, Any}, shunt::AbstractDict)
    if haskey(shunt, "re") && haskey(shunt, "im")
        delete!(record, "magnetizing_shunt")
        record["g"] = shunt["re"]
        record["b"] = shunt["im"]
    end
    return record
end
_split_shunt!(record::Dict{String, Any}, _) = record

const THREE_WINDING = TypeMapping(
    "ThreeWindingTransformer";
    windings = Dict(
        "primary_circuit" => "primary",
        "secondary_circuit" => "secondary",
        "tertiary_circuit" => "tertiary",
    ),
    # PSY5's 1-3 pair is PSY6's 3-1.
    renames = Dict("r_31" => "r_13", "x_31" => "x_13", "base_power_31" => "base_power_13"),
    reshape = split_magnetizing_shunt,
)

"""
The PSY6 snapshot's buses and arcs, by name, for fields PSY5 held by bus number and PSY6 by
reference (a regulated bus) and for values PSY6 moved onto a bus (a converter's AC voltage
target). Filled for each case by `index_psy6_buses!` before its components are compared.
"""
const PSY6_BUSES = Dict{String, Dict{String, Any}}(
    "number" => Dict{String, Any}(),
    "voltage_setpoint" => Dict{String, Any}(),
    "arc_ends" => Dict{String, Any}(),
)

function index_psy6_buses!(components::AbstractDict, system::AbstractDict)
    SYSTEM_BASE_POWER[] = Float64(get(system, "base_power", 100.0))
    foreach(empty!, values(PSY6_BUSES))
    for (name, bus) in get(components, "ACBus", Dict())
        PSY6_BUSES["number"][name] = get(bus, "number", nothing)
        PSY6_BUSES["voltage_setpoint"][name] = get(bus, "voltage_setpoint", nothing)
    end
    for (name, arc) in get(components, "Arc", Dict())
        PSY6_BUSES["arc_ends"][name] = (_ref_name(arc["from"]), _ref_name(arc["to"]))
    end
    return nothing
end

_ref_name(ref::AbstractDict) = get(ref, "name", nothing)
_ref_name(_) = nothing

"""A PSY6 bus reference as the PSY5 bus number it replaces; unset stays unset."""
bus_ref_as_number(ref::AbstractDict, _...) =
    get(PSY6_BUSES["number"], _ref_name(ref), ref)
bus_ref_as_number(v, _...) = v

"""
A transformer circuit's `regulated_bus` as PSY5's signed `regulated_bus_number` (PSS/E CONT):
the bus number, negative when `regulated_bus_orientation` is `FROM`.
"""
function regulated_bus_as_number(ref::AbstractDict, _, record)
    number = bus_ref_as_number(ref)
    if get(record, "regulated_bus_orientation", nothing) == "FROM"
        return _negated(number)
    end
    return number
end
_negated(number::Integer) = -number
_negated(v) = v
regulated_bus_as_number(v, _...) = v

"""
The `ac_setpoint_<side>` PSY5 held for each `AC_VOLTAGE` converter end, read back from the
`voltage_setpoint` of the bus it regulates: `remote_regulated_bus_<side>` if set, else its
terminal end of `arc`.
"""
function vsc_ac_setpoints_from_buses(record::Dict{String, Any})
    ends = get(PSY6_BUSES["arc_ends"], _ref_name(get(record, "arc", nothing)), nothing)
    for (side, end_index) in (("from", 1), ("to", 2))
        if get(record, "ac_control_$side", nothing) != "AC_VOLTAGE" || isnothing(ends)
            continue
        end
        bus = something(_ref_name(get(record, "remote_regulated_bus_$side", nothing)),
            ends[end_index])
        record["ac_setpoint_$side"] = get(PSY6_BUSES["voltage_setpoint"], bus, nothing)
    end
    return record
end

const TWO_WINDING = TypeMapping(
    "TwoWindingTransformer";
    flatten = ["circuit"],
    # PSY6 spells PSY5's Greek `α` in ASCII.
    renames = Dict("magnetizing_shunt" => "primary_shunt", "alpha" => "α"),
)

const TYPE_MAPPINGS = Dict{String, TypeMapping}(
    "Transformer2W" => TWO_WINDING,
    # PSY6 spells the voltage exponents in ASCII.
    "ExponentialLoad" => TypeMapping(
        "ExponentialLoad";
        renames = Dict("alpha" => "α", "beta" => "β"),
    ),
    # An AC_VOLTAGE converter's target is its regulated bus's `voltage_setpoint` in PSY6.
    "TwoTerminalVSCLine" => TypeMapping(
        "TwoTerminalVSCLine";
        reshape = vsc_ac_setpoints_from_buses,
    ),
    "TapTransformer" => TWO_WINDING,
    "PhaseShiftingTransformer" => TWO_WINDING,
    # One circuit per winding, each lifted under PSY5's per-winding names.
    "Transformer3W" => THREE_WINDING,
    "PhaseShiftingTransformer3W" => THREE_WINDING,
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

"""
A VSC DC voltage band read back in PSY6's kV, as the per unit of `rated_dc_voltage` PSY5
stored. The no-limit maximum, 999.9 in both versions, is left as is.
"""
kv_limits_as_per_unit(v::AbstractDict, _, record) =
    _limits_per_unit(v, get(record, "rated_dc_voltage", nothing))
kv_limits_as_per_unit(v, _...) = v

function _limits_per_unit(v::AbstractDict, rated::Real)
    if rated <= 0
        return v
    end
    return Dict{String, Any}(k => _limit_per_unit(x, rated) for (k, x) in v)
end
_limits_per_unit(v, _) = v

function _limit_per_unit(x::Real, rated::Real)
    if x == 999.9
        return x
    end
    return x / rated
end
_limit_per_unit(x, _) = x

"""
A VSC line's series conductance read back in PSY6's siemens, as the system-base per unit PSY5
stored on the DC voltage base (`rated_dc_voltage`, kV).
"""
siemens_as_dc_per_unit(v::Real, system::AbstractDict, record) =
    _siemens_per_unit(v, system["base_power"], get(record, "rated_dc_voltage", nothing))
siemens_as_dc_per_unit(v, _...) = v

function _siemens_per_unit(v::Real, base_power::Real, kv::Real)
    if kv <= 0
        return v
    end
    return v * kv^2 / base_power
end
_siemens_per_unit(v, _, _) = v

"""
The schema defaults the updater writes for `MarketBidCost` fields PSY5 does not have
(SCHEMA DEFAULTS WRITTEN); at these values they are dropped, any other is left and fails.
"""
const MARKET_BID_COST_DEFAULTS = Dict(
    "incremental_slope" => false,
    "decremental_slope" => false,
    "curve_style" => "VARIABLE",
    "curve_multistep" => "SINGLE_STEP",
)

"""A constant `LinearCurve` (no proportional term) as the scalar PSY5 held, else unchanged."""
function _constant_curve_as_scalar(curve::AbstractDict)
    data = something(get(curve, "function_data", nothing), Dict())
    if get(curve, "__type__", nothing) != "LinearCurve" ||
       get(data, "__type__", nothing) != "LinearFunctionData" ||
       get(data, "proportional_term", nothing) != 0.0
        return curve
    end
    return data["constant_term"]
end
_constant_curve_as_scalar(v) = v

"""
PSY6's `MarketBidCost{U}` in PSY5's form, using the owning component (`record`): the unit
type parameter dropped; `minimum_energy_offer` (\$/MWh at the unit's minimum power) as PSY5's
`no_load_cost` (\$/h), times that minimum in MW; a constant `shut_down` curve as its scalar;
`ZERO_OFFER_CURVE` as an unoffered (`nothing`) decremental side; and the schema defaults the
updater writes dropped. A shape outside these is left as read and fails.
"""
function market_bid_cost_as_psy5(cost::AbstractDict, system::AbstractDict, record)
    m = match(r"^MarketBidCost\{(\w+)\}$", string(get(cost, "__type__", "")))
    if isnothing(m) || !haskey(UNIT_SYSTEM_NAMES, m[1])
        return cost
    end
    aligned = Dict{String, Any}(cost)
    aligned["__type__"] = "MarketBidCost"
    for (field, default) in MARKET_BID_COST_DEFAULTS
        if get(aligned, field, nothing) == default
            delete!(aligned, field)
        end
    end
    aligned["shut_down"] = _constant_curve_as_scalar(get(cost, "shut_down", nothing))
    if is_zero_offer_curve(curve_units_as_field(something(
        get(cost, "decremental_offer_curves", nothing), Dict{String, Any}())))
        aligned["decremental_offer_curves"] = nothing
    end
    no_load = _no_load_cost(
        _constant_curve_as_scalar(get(cost, "minimum_energy_offer", nothing)),
        get(record, "active_power_limits", nothing),
        system["base_power"],
    )
    if !isnothing(no_load)
        delete!(aligned, "minimum_energy_offer")
        aligned["no_load_cost"] = no_load
    elseif _constant_curve_as_scalar(get(cost, "minimum_energy_offer", nothing)) == 0.0
        # No minimum power to convert by (a HybridSystem): the updater kept no_load_cost in
        # ext and wrote this zero-cost default, flagged under SCHEMA DEFAULTS WRITTEN.
        delete!(aligned, "minimum_energy_offer")
    end
    return aligned
end
market_bid_cost_as_psy5(v, _...) = v

# The snapshot reads limits on the system base, so the minimum in MW is min x base power.
_no_load_cost(offer::Real, limits::AbstractDict, base_power::Real) =
    offer * limits["min"] * base_power
_no_load_cost(_, _, _) = nothing

"""The value unchanged; for a rule that only renames."""
same(v, _...) = v

"""
A DC converter current read back in PSY6's kA, in the A PSY5 stored. PSY6's no-limit value
(9999 kA) is PSY5's PSS/E-parsed no-limit (9999), so it is left as is.
"""
ka_to_amperes(v::Real, _...) = v == 9999.0 ? v : v * 1000
ka_to_amperes(v, _...) = v

"""
PSY6's `SwitchedAdmittance.solved_admittance` (a susceptance) as the complex `Y` PSY5 held.
PSY6 documents it as PSS/E BINIT, the solved total; PSY5's PSS/E parser put BINIT in `Y` with a
zero conductance. Unset means no solved value, which is PSY5's `Y = 0`.
"""
as_switched_admittance_y(v::Real, _...) = Dict{String, Any}("re" => 0.0, "im" => v)
as_switched_admittance_y(::Nothing, _...) = Dict{String, Any}("re" => 0.0, "im" => 0.0)
as_switched_admittance_y(v, _...) = v

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
    # MarketBidCost's PSY6 reshaping, read back with the owner's minimum power.
    FieldRule("*", "operation_cost", "operation_cost", market_bid_cost_as_psy5),
    # Regulated buses: a PSS/E bus number in PSY5, a bus reference in PSY6.
    FieldRule("*", "regulated_bus", "regulated_bus_number", regulated_bus_as_number),
    FieldRule(
        "SwitchedAdmittance",
        "remote_regulated_bus",
        "regulated_bus_number",
        bus_ref_as_number,
    ),
    FieldRule(
        "TwoTerminalVSCLine",
        "remote_regulated_bus_from",
        "remote_bus_control_from",
        bus_ref_as_number,
    ),
    FieldRule(
        "TwoTerminalVSCLine",
        "remote_regulated_bus_to",
        "remote_bus_control_to",
        bus_ref_as_number,
    ),
    # VSC series conductance: system-base pu on the DC voltage in PSY5, S in PSY6.
    FieldRule("TwoTerminalVSCLine", "g", "g", siemens_as_dc_per_unit),
    # VSC DC voltage limits: per unit of rated_dc_voltage in PSY5, kV in PSY6.
    FieldRule(
        "TwoTerminalVSCLine",
        "voltage_limits_from",
        "voltage_limits_from",
        kv_limits_as_per_unit,
    ),
    FieldRule("TwoTerminalVSCLine", "voltage_limits_to", "voltage_limits_to", kv_limits_as_per_unit),
    # DC converter currents: A in PSY5, kA in PSY6 (schema 0.3+).
    FieldRule("TwoTerminalVSCLine", "dc_current", "dc_current", ka_to_amperes),
    FieldRule("TwoTerminalVSCLine", "max_dc_current_from", "max_dc_current_from", ka_to_amperes),
    FieldRule("TwoTerminalVSCLine", "max_dc_current_to", "max_dc_current_to", ka_to_amperes),
    FieldRule("InterconnectingConverter", "dc_current", "dc_current", ka_to_amperes),
    FieldRule("InterconnectingConverter", "max_dc_current", "max_dc_current", ka_to_amperes),
    # SwitchedAdmittance: PSY6 dropped the base `Y` for `solved_admittance` (PSS/E BINIT),
    # renamed the per-block `initial_status` (PSS/E `Si`) to `number_engaged`, and split PSS/E's
    # VSWLO/VSWHI band into a voltage band and a reactive-range band, one per control mode (the
    # other is unset; FIXED uses neither).
    FieldRule("SwitchedAdmittance", "solved_admittance", "Y", as_switched_admittance_y),
    FieldRule("SwitchedAdmittance", "number_engaged", "initial_status", same),
    FieldRule("SwitchedAdmittance", "voltage_limits", "admittance_limits", same),
    FieldRule(
        "SwitchedAdmittance",
        "reactive_power_range_limits",
        "admittance_limits",
        same,
    ),
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
PSY6 also records a `FuelCurve`'s fuel units as a type parameter. PSY5 had none: its fuel
curves are MMBtu per hour by convention, so only that parameter is taken as PSY5's; any other
is left in place and fails.
"""
const PSY5_FUEL_UNITS_PARAMETER = ", FreeUnits{(hr⁻¹, MMBtu), 𝐋² 𝐌 𝐓⁻³, nothing}}"

"""
PSY6 moved a cost curve's `power_units` field into a type parameter:
`CostCurve{LinearCurve, NaturalUnit}` is PSY5's `CostCurve{LinearCurve}` with
`power_units = NATURAL_UNITS`.
"""
function curve_units_as_field(d::AbstractDict)
    type_name = replace(string(get(d, "__type__", "")), PSY5_FUEL_UNITS_PARAMETER => "}")
    m = match(r"^(CostCurve|FuelCurve)\{(.+), (\w+)\}$", type_name)
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
    type_name = string(get(d, "__type__", ""))
    if !startswith(type_name, "LossCurve{") || !haskey(d, "value_curve")
        return d
    end
    if occursin(", SystemBaseUnit", type_name)
        return _constant_term_in_mw(d["value_curve"])
    end
    return d["value_curve"]
end

"""
A linear loss curve read back in system base, with its constant loss in the MW PSY5 always
stored (the proportional term is MW per MW, the same in either). Any other curve shape is left
as is and compared as read.
"""
function _constant_term_in_mw(curve::AbstractDict)
    data = get(curve, "function_data", nothing)
    if get(something(data, Dict()), "__type__", nothing) != "LinearFunctionData"
        return curve
    end
    scaled = Dict{String, Any}(data)
    scaled["constant_term"] = data["constant_term"] * SYSTEM_BASE_POWER[]
    return merge(Dict{String, Any}(curve), Dict{String, Any}("function_data" => scaled))
end
_constant_term_in_mw(curve) = curve

"""The PSY6 system's base power (MVA), set by `index_psy6_buses!` for the case being compared."""
const SYSTEM_BASE_POWER = Ref(100.0)

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
    # Regulated buses PSY6 leaves unset: no regulated bus (PSY5's 0), or the device's own bus
    # (a shunt's bus, a converter's terminal), which PSY6 says by leaving the field unset.
    Expected(
        "value",
        "*Transformer",
        "regulated_bus_number",
        "PSY5's 0 (no regulated bus) is PSY6's unset regulated_bus",
        (psy5, psy6) -> psy5 == 0 && isnothing(psy6),
    ),
    Expected(
        "value",
        "SwitchedAdmittance",
        "regulated_bus_number",
        "PSY6 leaves remote_regulated_bus unset for the shunt's own bus (PSY5's 0 or its own number)",
        (_, psy6) -> isnothing(psy6),
    ),
    Expected(
        "value",
        "TwoTerminalVSCLine",
        "remote_bus_control_*",
        "PSY6 leaves remote_regulated_bus unset for the converter's terminal bus (PSY5's 0 or its number)",
        (_, psy6) -> isnothing(psy6),
    ),
    # PSY5's constructor-default "no limit" DC current (1e8 A) is PSY6's 9999 kA.
    Expected(
        "value",
        "*",
        "max_dc_current*",
        "PSY5's default no-limit DC current (1e8 A) is the schema's 9999 kA",
        (psy5, psy6) -> psy5 == 1.0e8 && psy6 == 9999.0,
    ),
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
    # Dynamic models with no 0.2 schema home, kept dropped for now: induction machines and the
    # periodic source are dynamic injectors; `DynamicBranch` wraps a static `Line`, which is
    # lost with it.
    Expected(
        "missing_component",
        "*InductionMachine",
        "",
        "dynamic models are not in the 0.2 schema; dropped for now",
    ),
    Expected(
        "missing_component",
        "PeriodicVariableSource",
        "",
        "dynamic models are not in the 0.2 schema; dropped for now",
    ),
    Expected(
        "missing_component",
        "DynamicBranch",
        "",
        "dynamic models are not in the 0.2 schema; dropped for now (its static Line with it)",
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
        "*_group_number",
        "PSY6 drops WindingGroupNumber; the angle survives as each circuit's α",
    ),
    Expected(
        "missing_field",
        "Transformer3W",
        "available",
        "Transformer3W availability is per-circuit in PSY6",
    ),
    Expected(
        "value",
        "*Transformer3W",
        "available_*",
        "transformer out of service at the top level: each circuit is available only if the " *
        "transformer and its winding both are",
        (psy5, psy6) -> psy5 === true && psy6 === false,
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
