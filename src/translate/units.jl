# Unit conversion from how PSY5 stored a field to the unit the PSY6 schema declares for it.
#
# PSY6 side: the schema's `x-unit` annotations (`ICOM.declared_unit` and friends). PSY5 side:
# `PSY5_DEVICE_BASE_FIELDS` (generated from PSY5's descriptors by
# `scripts/psy5_units/generate_psy5_units.jl`) plus `PSY5_STORAGE`, the hand-listed exceptions.
# A per-unit PSY6 field is copied; a physical one is converted. A physical PSY6 field whose PSY5
# storage is unknown is never copied silently: it is reported as an unverified unit.

include("psy5_units_generated.jl")

"""How PSY5 stored a field's value."""
abstract type Psy5Storage end

"""Per unit on the component's `base_power` (the system base if it has none)."""
struct DeviceBasePU <: Psy5Storage end

"""Per unit on the system base, whatever the component's own base."""
struct SystemBasePU <: Psy5Storage end

"""Already in the physical unit PSY6 declares."""
struct Natural <: Psy5Storage end

"""Natural, but per hour where PSY6 is per second."""
struct PerHour <: Psy5Storage end

"""Current in A, where the schema declares kA."""
struct Amperes <: Psy5Storage end

"""Natural power, which a per-unit PSY6 field takes on the component's base."""
struct NaturalPower <: Psy5Storage end

"""Per unit of the base voltage at one end of the component's arc (1 `from`, 2 `to`)."""
struct ArcEndVoltagePU <: Psy5Storage
    end_index::Int
end

"""A multiple of another PSY5 value, named by `path` in the record (e.g. a fraction of a limit)."""
struct RelativeTo <: Psy5Storage
    path::Vector{String}
end

"""A VSC's DC voltage limits: `RelativeTo` `rated_dc_voltage`, but `DC_VOLTAGE_NO_LIMIT` stays."""
struct DCVoltageLimits <: Psy5Storage end

"""Per unit on the system base power and the kV at `path` in the record, not a bus's."""
struct SystemBasePUOnVoltage <: Psy5Storage
    path::Vector{String}
end

"""PSY5 never annotated the field and it is not in `PSY5_STORAGE`."""
struct UnknownStorage <: Psy5Storage end

"""
PSY5 fields not stored as device-base per unit, which PSY5's descriptors do not record, by
type and field name as it reaches `build_kwargs` (after translator renames). `"*"` matches any
type. Comments cite the PSY5 convention.
"""
const PSY5_STORAGE = Dict{Tuple{String, String}, Psy5Storage}(
    # PSY5 `get_requirement` divides MW by the system base.
    ("VariableReserve", "requirement") => SystemBasePU(),
    ("ConstantReserve", "requirement") => SystemBasePU(),
    ("VariableReserveNonSpinning", "requirement") => SystemBasePU(),
    ("ConstantReserveNonSpinning", "requirement") => SystemBasePU(),
    ("ConstantReserveGroup", "requirement") => SystemBasePU(),
    # "Fixed admittance in p.u. (SYSTEM_BASE)".
    ("FixedAdmittance", "y") => SystemBasePU(),
    # PSS/E BINIT and B1..B8, rescaled by PSY5's parser (`parsers/pm_io/data.jl`).
    ("SwitchedAdmittance", "solved_admittance") => SystemBasePU(),
    ("SwitchedAdmittance", "y_increase") => SystemBasePU(),
    # PSS/E VSWLO/VSWHI as read.
    ("SwitchedAdmittance", "voltage_limits") => Natural(),
    ("SwitchedAdmittance", "reactive_power_range_limits") => Natural(),
    # "relative to the `storage_level_limits.max`"; PSY6 declares absolute levels.
    ("HydroReservoir", "initial_level") => RelativeTo(["storage_level_limits", "max"]),
    ("HydroReservoir", "level_targets") => RelativeTo(["storage_level_limits", "max"]),
    # "in m^3, m, or MWh" / "in m^3/h or MW": natural, flows per hour.
    ("HydroReservoir", "storage_level_limits") => Natural(),
    ("HydroReservoir", "inflow") => PerHour(),
    ("HydroReservoir", "outflow") => PerHour(),
    ("HydroReservoir", "spillage_limits") => PerHour(),
    # LCC impedances are system-base per unit on the circuit's own voltage, not a bus's: PSY5's
    # PSS/E parser divides `RDC` by `VSCHD^2 / baseMVA` and `RC`/`XC`/`XCAP` by
    # `EBAS^2 / baseMVA` (`parsers/pm_io/psse.jl`).
    ("TwoTerminalLCCLine", "r") => SystemBasePUOnVoltage(["scheduled_dc_voltage"]),
    ("TwoTerminalLCCLine", "rectifier_rc") =>
        SystemBasePUOnVoltage(["rectifier_base_voltage"]),
    ("TwoTerminalLCCLine", "rectifier_xc") =>
        SystemBasePUOnVoltage(["rectifier_base_voltage"]),
    ("TwoTerminalLCCLine", "rectifier_capacitor_reactance") =>
        SystemBasePUOnVoltage(["rectifier_base_voltage"]),
    ("TwoTerminalLCCLine", "inverter_rc") =>
        SystemBasePUOnVoltage(["inverter_base_voltage"]),
    ("TwoTerminalLCCLine", "inverter_xc") =>
        SystemBasePUOnVoltage(["inverter_base_voltage"]),
    ("TwoTerminalLCCLine", "inverter_capacitor_reactance") =>
        SystemBasePUOnVoltage(["inverter_base_voltage"]),
    ("TwoTerminalLCCLine", "compounding_resistance") => Natural(),
    ("TwoTerminalLCCLine", "rectifier_base_voltage") => Natural(),
    ("TwoTerminalLCCLine", "inverter_base_voltage") => Natural(),
    # From `transfer_setpoint` (`_lcc_control`): MW (power mode) or A (current mode).
    ("TwoTerminalLCCLine", "power_transfer_setpoint") => NaturalPower(),
    ("TwoTerminalLCCLine", "current_transfer_setpoint") => Natural(),
    ("TwoTerminalLCCLine", "scheduled_dc_voltage") => Natural(),
    ("TwoTerminalLCCLine", "switch_mode_voltage") => Natural(),
    ("TwoTerminalLCCLine", "min_compounding_voltage") => Natural(),
    # VSC `g` is on the DC voltage base (`DCSET`, now `rated_dc_voltage`), not an AC bus's; DC
    # voltage limits are per unit of `rated_dc_voltage`; DC currents are in A.
    ("TwoTerminalVSCLine", "g") => SystemBasePUOnVoltage(["rated_dc_voltage"]),
    ("TwoTerminalVSCLine", "voltage_limits_from") => DCVoltageLimits(),
    ("TwoTerminalVSCLine", "voltage_limits_to") => DCVoltageLimits(),
    ("TwoTerminalVSCLine", "rated_dc_voltage") => Natural(),
    # From `dc_setpoint_*` / `ac_setpoint_*` (`_vsc_setpoints`): DC power in system-base per
    # unit, DC voltage per unit of `rated_dc_voltage`.
    ("TwoTerminalVSCLine", "dc_power_setpoint_from") => SystemBasePU(),
    ("TwoTerminalVSCLine", "dc_power_setpoint_to") => SystemBasePU(),
    ("TwoTerminalVSCLine", "dc_voltage_setpoint_from") =>
        RelativeTo(["rated_dc_voltage"]),
    ("TwoTerminalVSCLine", "dc_voltage_setpoint_to") =>
        RelativeTo(["rated_dc_voltage"]),
    ("TwoTerminalVSCLine", "power_factor_setpoint_from") => Natural(),
    ("TwoTerminalVSCLine", "rated_ac_voltage_from") => Natural(),
    ("TwoTerminalVSCLine", "rated_ac_voltage_to") => Natural(),
    ("TwoTerminalVSCLine", "power_factor_setpoint_to") => Natural(),
    ("TwoTerminalVSCLine", "dc_current") => Amperes(),
    ("TwoTerminalVSCLine", "max_dc_current_from") => Amperes(),
    ("TwoTerminalVSCLine", "max_dc_current_to") => Amperes(),
    ("InterconnectingConverter", "dc_current") => Amperes(),
    ("InterconnectingConverter", "max_dc_current") => Amperes(),
    ("TModelHVDCLine", "r") => SystemBasePU(),
    ("Area", "load_response") => Natural(),
    ("*", "base_power") => Natural(),
    ("*", "base_voltage") => Natural(),
)

"""How PSY5 stored `field` on `psy5_type`."""
function psy5_storage(psy5_type::AbstractString, field::AbstractString)
    key = (String(psy5_type), String(field))
    if haskey(PSY5_STORAGE, key)
        return PSY5_STORAGE[key]
    elseif haskey(PSY5_DEVICE_BASE_FIELDS, key)
        return DeviceBasePU()
    elseif haskey(PSY5_STORAGE, ("*", key[2]))
        return PSY5_STORAGE[("*", key[2])]
    elseif startswith(key[2], "base_power") || startswith(key[2], "base_voltage")
        return Natural()
    end
    return UnknownStorage()
end

"""Values a unit discriminator can take, in order of preference."""
const UNIT_BASES = (
    :COMPONENT_BASE, :NATURAL_UNITS, :COMPONENT_MVAR, :MWH, :MWMIN,
    :USABLE_VOLUME, :TOTAL_VOLUME, :HEAD, :ENERGY,
)

"""Discriminators whose value is data in the record, not a basis the updater chooses."""
const DATA_DISCRIMINATORS = Set([:level_data_type])

"""Power units, in which a per-unit value is a multiple of a base MVA."""
const POWER_UNITS = Set(["MW", "MVA", "MVAr", "MWh", "MW/min", "MVA/min", "MVAr/min"])

"""Physical units PSY5 commonly stored per unit; an unknown-storage field in one is reported."""
const PER_UNIT_PRONE_UNITS =
    union(POWER_UNITS, Set(["ohm", "S", "kV", "A", "H", "F", "kV/MW", "MW/Hz"]))

_declared_unit(T, field::Symbol, basis::Symbol) =
    try
        ICOM.declared_unit(T, Val(field), Val(basis))
    catch
        nothing
    end

_unit_discriminator(T, field::Symbol) =
    try
        ICOM.unit_discriminator(T, Val(field))
    catch
        nothing
    end

_is_per_unit(unit::AbstractString) = startswith(unit, "pu")

"""
`(unit, discriminator => basis)` PSY6 declares for `field` of `T`; either is `nothing` when
absent or when the updater need not write the basis. A per-unit basis is preferred, since
PSY5's device-base values already are per unit on `base_power`. A data discriminator is read
from `raw`; any other falls back to its first power-unit basis.
"""
function target_unit(::Type{T}, field::Symbol, raw::AbstractDict) where {T}
    if !ICOM.has_declared_unit(T, Val(field))
        return (nothing, nothing)
    end
    discriminator = _unit_discriminator(T, field)
    if isnothing(discriminator)
        return (ICOM.declared_unit(T, Val(field)), nothing)
    end
    if discriminator in DATA_DISCRIMINATORS
        value = get(raw, string(discriminator), nothing)
        if isnothing(value)
            return (nothing, nothing)
        end
        return (_declared_unit(T, field, Symbol(value)), nothing)
    end
    for basis in UNIT_BASES
        unit = _declared_unit(T, field, basis)
        if !isnothing(unit) && _is_per_unit(unit)
            return (unit, discriminator => string(basis))
        end
    end
    for basis in UNIT_BASES
        unit = _declared_unit(T, field, basis)
        if !isnothing(unit) && unit in POWER_UNITS
            return (unit, discriminator => string(basis))
        end
    end
    return (nothing, nothing)
end

"""
Bus voltage bases, arc endpoints and bus numbers of a PSY5 case: the bases convert impedances
and voltages, the numbers resolve fields PSY5 names a bus by number.
"""
struct BusIndex
    base_voltage::Dict{String, Float64}
    arcs::Dict{String, Tuple{String, String}}
    uuid_by_number::Dict{Int, String}
    number_by_uuid::Dict{String, Int}
end

BusIndex() = BusIndex(Dict{String, Float64}(), Dict{String, Tuple{String, String}}())

"""A `BusIndex` with voltage bases and arcs but no bus numbers."""
function BusIndex(
    base_voltage::AbstractDict{String, Float64},
    arcs::AbstractDict{String, Tuple{String, String}},
)
    return BusIndex(base_voltage, arcs, Dict{Int, String}(), Dict{String, Int}())
end

function BusIndex(components)
    index = BusIndex()
    for raw in components
        type_name = component_type(raw)
        if type_name == "ACBus" && haskey(raw, "number")
            index.uuid_by_number[Int(raw["number"])] = component_uuid(raw)
            index.number_by_uuid[component_uuid(raw)] = Int(raw["number"])
        end
        kv = get(raw, "base_voltage", nothing)
        if type_name in ("ACBus", "DCBus") && !isnothing(kv) && kv > 0
            index.base_voltage[component_uuid(raw)] = Float64(kv)
        elseif type_name == "Arc"
            index.arcs[component_uuid(raw)] =
                (reference_uuid(raw["from"]), reference_uuid(raw["to"]))
        end
    end
    return index
end

"""A component's PSY5 record and the bases needed to convert its fields."""
struct ComponentUnits
    psy5_type::String
    raw::AbstractDict
    component_base::Float64
    system_base::Float64
    buses::BusIndex
end

"""
The component's voltage base (kV) from its `bus` or its arc's `from` bus, or `nothing`.
Transformers, whose ends differ, have per-unit impedances that are never converted here.
"""
function voltage_base(units::ComponentUnits)
    bus = get(units.raw, "bus", nothing)
    if is_reference(bus)
        return get(units.buses.base_voltage, reference_uuid(bus), nothing)
    end
    return arc_end_voltage(units, 1)
end

"""The base voltage (kV) of one end of the component's arc (1 `from`, 2 `to`), or `nothing`."""
function arc_end_voltage(units::ComponentUnits, end_index::Int)
    arc = get(units.raw, "arc", nothing)
    if !is_reference(arc)
        return nothing
    end
    ends = get(units.buses.arcs, reference_uuid(arc), nothing)
    if isnothing(ends)
        return nothing
    end
    return get(units.buses.base_voltage, ends[end_index], nothing)
end

_scale(value::Bool, ::Real) = value
_scale(value::Real, factor::Real) = value * factor
_scale(::Nothing, ::Real) = nothing
_scale(value::AbstractVector, factor::Real) = [_scale(v, factor) for v in value]
_scale(value::AbstractDict, factor::Real) =
    Dict{String, Any}(
        k => (k == "__metadata__" ? v : _scale(v, factor)) for (k, v) in value
    )
_scale(value, ::Real) = value

function _lookup(raw::AbstractDict, path::Vector{String})
    value = raw
    for key in path
        value = get(value, key, nothing)
        if isnothing(value)
            return nothing
        end
    end
    return value
end

"""A value whose unit could not be established; see `convert_units`."""
struct UnverifiedUnit
    reason::String
end

"""A value on a non-physical PSY5 base (a voltage of 0 or less), reported as an invalid value."""
struct NonPhysicalBase
    reason::String
end

_base(::DeviceBasePU, units::ComponentUnits) = units.component_base
_base(::SystemBasePU, units::ComponentUnits) = units.system_base

"""The factor from per unit on `base` MVA to `unit`, or `nothing` if not reachable."""
function _per_unit_factor(unit::AbstractString, base::Real, units::ComponentUnits)
    if unit in POWER_UNITS
        return base
    elseif unit in ("ohm", "S", "kV")
        kv = voltage_base(units)
        if isnothing(kv)
            return nothing
        end
        z_base = kv^2 / base
        if unit == "ohm"
            return z_base
        elseif unit == "S"
            return 1 / z_base
        end
        return kv
    end
    return nothing
end

"""
`value` (as PSY5 stored it) in the unit PSY6 declares (`unit`, from `target_unit`), or an
`UnverifiedUnit` or `NonPhysicalBase` when that cannot be established.
"""
convert_units(::Psy5Storage, ::Nothing, value, ::ComponentUnits) = value
convert_units(::Natural, ::AbstractString, value, ::ComponentUnits) = value

convert_units(storage::RelativeTo, ::AbstractString, value, units::ComponentUnits) =
    _relative(value, _lookup(units.raw, storage.path), storage)

"""The "no limit" maximum of a VSC DC voltage band: 999.9 in PSY5 (per unit) and PSY6 (kV)."""
const DC_VOLTAGE_NO_LIMIT = 999.9

function convert_units(
    ::DCVoltageLimits,
    unit::AbstractString,
    value::AbstractDict,
    units::ComponentUnits,
)
    converted = convert_units(RelativeTo(["rated_dc_voltage"]), unit, value, units)
    return _keep_no_limit(converted, get(value, "max", nothing))
end
convert_units(::DCVoltageLimits, unit::AbstractString, value, units::ComponentUnits) =
    convert_units(RelativeTo(["rated_dc_voltage"]), unit, value, units)

function _keep_no_limit(converted::AbstractDict, original_max)
    if original_max == DC_VOLTAGE_NO_LIMIT
        converted["max"] = DC_VOLTAGE_NO_LIMIT
    end
    return converted
end
_keep_no_limit(converted, _) = converted

_relative(value, reference::Real, storage::RelativeTo) =
    if reference > 0
        _scale(value, reference)
    else
        NonPhysicalBase("relative to $(join(storage.path, ".")) = $reference")
    end
_relative(_, ::Any, storage::RelativeTo) =
    UnverifiedUnit("relative to $(join(storage.path, ".")), which is missing")

"""The schema's "no limit" DC current in kA (PowerSystems' `INFINITE_CURRENT`)."""
const NO_CURRENT_LIMIT_KA = 9999.0

"""PSY5's "no limit" DC currents (PSS/E IMAX of 0, and the constructor default)."""
const PSY5_NO_CURRENT_LIMITS = (9999.0, 1.0e8)

function convert_units(::Amperes, unit::AbstractString, value::Real, ::ComponentUnits)
    if unit == "A"
        return value
    elseif unit != "kA"
        return UnverifiedUnit("no conversion from A to $unit")
    elseif value in PSY5_NO_CURRENT_LIMITS
        return NO_CURRENT_LIMIT_KA
    end
    return value / 1000
end
convert_units(::Amperes, ::AbstractString, value, ::ComponentUnits) = value

convert_units(::PerHour, unit::AbstractString, value, ::ComponentUnits) =
    endswith(unit, "/s") ? _scale(value, 1 / 3600) : value

function convert_units(::NaturalPower, unit::AbstractString, value, units::ComponentUnits)
    if _is_per_unit(unit)
        return _scale(value, 1 / units.component_base)
    end
    if unit in POWER_UNITS
        return value
    end
    return UnverifiedUnit("no conversion from MW to $unit")
end

function convert_units(
    storage::ArcEndVoltagePU,
    unit::AbstractString,
    value,
    units::ComponentUnits,
)
    kv = arc_end_voltage(units, storage.end_index)
    if unit != "kV" || isnothing(kv)
        return UnverifiedUnit("per unit of an arc end's voltage, to $unit")
    end
    return _scale(value, kv)
end

function convert_units(
    storage::Union{DeviceBasePU, SystemBasePU},
    unit::AbstractString,
    value,
    units::ComponentUnits,
)
    base = _base(storage, units)
    if _is_per_unit(unit)
        return _scale(value, base / units.component_base)
    end
    factor = _per_unit_factor(unit, base, units)
    if isnothing(factor)
        return UnverifiedUnit("no conversion from per unit to $unit")
    end
    return _scale(value, factor)
end

function convert_units(
    storage::SystemBasePUOnVoltage,
    unit::AbstractString,
    value,
    units::ComponentUnits,
)
    return _on_voltage(value, unit, _lookup(units.raw, storage.path), storage, units)
end

function _on_voltage(value, unit, kv::Real, storage::SystemBasePUOnVoltage, units)
    if kv <= 0
        return NonPhysicalBase("on $(join(storage.path, ".")) = $kv")
    end
    z_base = kv^2 / units.system_base
    if unit == "ohm"
        return _scale(value, z_base)
    elseif unit == "S"
        return _scale(value, 1 / z_base)
    end
    return UnverifiedUnit("per unit on $(join(storage.path, ".")), to $unit")
end
_on_voltage(_, _, ::Any, storage::SystemBasePUOnVoltage, _) =
    UnverifiedUnit("on $(join(storage.path, ".")), which is missing")

function convert_units(::UnknownStorage, unit::AbstractString, value, ::ComponentUnits)
    if unit in PER_UNIT_PRONE_UNITS
        return UnverifiedUnit("PSY5 storage unknown; PSY6 declares $unit")
    end
    return value
end
