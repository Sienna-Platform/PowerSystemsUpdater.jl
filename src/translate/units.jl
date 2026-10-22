# Unit conversion between the values PSY5 stored and the units the PSY6 schema declares.
#
# Every field `build_kwargs` writes is converted by one rule, from two sources of metadata:
#
#   - PSY6: the schema's `x-unit` annotations, which the model packages expose as
#     `ICOM.unit_discriminator` / `ICOM.declared_unit` / `ICOM.declared_quantity`.
#   - PSY5: how PSY5 stored the field. `PSY5_DEVICE_BASE_FIELDS` is generated from PSY5's
#     descriptors (`scripts/psy5_units/generate_psy5_units.jl`); `PSY5_STORAGE` lists by hand
#     the fields PSY5 stored some other way without annotating them.
#
# A field whose PSY6 unit is per unit is copied, as PSY5's device-base storage already is. A
# field with a physical PSY6 unit is converted from PSY5's per-unit or relative value. A field
# whose PSY6 unit is physical and whose PSY5 storage is not known is never silently copied:
# it is reported as an unverified unit (and kept in `ext` when the field is optional).

include("psy5_units_generated.jl")

"""How PSY5 stored a field's value."""
abstract type Psy5Storage end

"""Per unit on the component's own `base_power` (the system base for a component with none)."""
struct DeviceBasePU <: Psy5Storage end

"""Per unit on the system base, whatever the component's own base."""
struct SystemBasePU <: Psy5Storage end

"""Already in the physical unit PSY6 declares."""
struct Natural <: Psy5Storage end

"""Natural, but per hour where PSY6 is per second (`m3/h` against `m3/s`)."""
struct PerHour <: Psy5Storage end

"""Natural power (MW, MVA, MVAr), which a per-unit PSY6 field takes on the component's base."""
struct NaturalPower <: Psy5Storage end

"""
Per unit of the base voltage of one end of the component's arc (`end_index` 1 for `from`, 2
for `to`): a converter setpoint referred to its own AC terminal.
"""
struct ArcEndVoltagePU <: Psy5Storage
    end_index::Int
end

"""
A multiple of another PSY5 value: a level stored as a fraction of `storage_level_limits.max`,
or a voltage in per unit of `rated_dc_voltage`. `path` names that value in the PSY5 record.
"""
struct RelativeTo <: Psy5Storage
    path::Vector{String}
end

"""
Per unit on the system base power and the voltage (kV) named by `path` in the PSY5 record,
rather than a bus's: an LCC line's impedances, on the base of the circuit they sit in.
"""
struct SystemBasePUOnVoltage <: Psy5Storage
    path::Vector{String}
end

"""Not recorded anywhere: PSY5 never annotated the field and it is not in `PSY5_STORAGE`."""
struct UnknownStorage <: Psy5Storage end

"""
PSY5 fields stored some way other than device-base per unit, which PSY5's descriptors do not
record, keyed by PSY5 type and by the field's name as it reaches `build_kwargs` (after any
translator rename, e.g. `FixedAdmittance`'s `Y` → `y`). `"*"` matches any type. Each entry
cites where the PSY5 convention is stated.
"""
const PSY5_STORAGE = Dict{Tuple{String, String}, Psy5Storage}(
    # Reserve requirements: system-base per unit (PSY5 `get_requirement` divides MW by the
    # system base); PSY6 declares MW.
    ("VariableReserve", "requirement") => SystemBasePU(),
    ("ConstantReserve", "requirement") => SystemBasePU(),
    ("VariableReserveNonSpinning", "requirement") => SystemBasePU(),
    ("ConstantReserveNonSpinning", "requirement") => SystemBasePU(),
    ("ConstantReserveGroup", "requirement") => SystemBasePU(),
    # "Fixed admittance in p.u. (SYSTEM_BASE)"; PSY6 declares MVAr (COMPONENT_MVAR).
    ("FixedAdmittance", "y") => SystemBasePU(),
    # "Initial level of the reservoir relative to the `storage_level_limits.max`" and level
    # targets "as a fraction of" it; PSY6 declares absolute levels.
    ("HydroReservoir", "initial_level") => RelativeTo(["storage_level_limits", "max"]),
    ("HydroReservoir", "level_targets") => RelativeTo(["storage_level_limits", "max"]),
    # "in m^3, m, or MWh" / "in m^3/h or MW": natural, flows per hour.
    ("HydroReservoir", "storage_level_limits") => Natural(),
    ("HydroReservoir", "inflow") => PerHour(),
    ("HydroReservoir", "outflow") => PerHour(),
    ("HydroReservoir", "spillage_limits") => PerHour(),
    # Two-terminal LCC: impedances "in system p.u. (SYSTEM_BASE)", voltages "in kV",
    # compounding resistance "in ohms". The impedance base voltage is the circuit's own, not a
    # bus's: PSY5's PSS/E parser divides `RDC` by `VSCHD^2 / baseMVA` and each converter's
    # `RC`/`XC`/`XCAP` by `EBAS^2 / baseMVA` (`parsers/pm_io/psse.jl`).
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
    # From PSY5's `transfer_setpoint` (`_lcc_control`): "in MW units" (power mode) or "in
    # Amperes units" (current mode); "must not be specified in per-unit".
    ("TwoTerminalLCCLine", "power_transfer_setpoint") => NaturalPower(),
    ("TwoTerminalLCCLine", "current_transfer_setpoint") => Natural(),
    ("TwoTerminalLCCLine", "scheduled_dc_voltage") => Natural(),
    ("TwoTerminalLCCLine", "switch_mode_voltage") => Natural(),
    ("TwoTerminalLCCLine", "min_compounding_voltage") => Natural(),
    # Two-terminal VSC: "series conductance ... in pu (SYSTEM_BASE)"; DC voltage limits "in per
    # unit" of the link's DC voltage base, `rated_dc_voltage` ("Rated (base) DC voltage ... in
    # kV"), not of the AC buses either end; DC currents "(A)".
    ("TwoTerminalVSCLine", "g") => SystemBasePU(),
    ("TwoTerminalVSCLine", "voltage_limits_from") => RelativeTo(["rated_dc_voltage"]),
    ("TwoTerminalVSCLine", "voltage_limits_to") => RelativeTo(["rated_dc_voltage"]),
    ("TwoTerminalVSCLine", "rated_dc_voltage") => Natural(),
    # From PSY5's `dc_setpoint_*` / `ac_setpoint_*` (`_vsc_setpoints`): DC power "in per-unit
    # (SYSTEM_BASE)", DC voltage "in per-unit of `rated_dc_voltage`", AC voltage "entered in
    # per unit" (of the converter's AC bus), power factor dimensionless.
    ("TwoTerminalVSCLine", "dc_power_setpoint_from") => SystemBasePU(),
    ("TwoTerminalVSCLine", "dc_power_setpoint_to") => SystemBasePU(),
    ("TwoTerminalVSCLine", "dc_voltage_setpoint_from") =>
        RelativeTo(["rated_dc_voltage"]),
    ("TwoTerminalVSCLine", "dc_voltage_setpoint_to") =>
        RelativeTo(["rated_dc_voltage"]),
    ("TwoTerminalVSCLine", "ac_voltage_setpoint_from") => ArcEndVoltagePU(1),
    ("TwoTerminalVSCLine", "ac_voltage_setpoint_to") => ArcEndVoltagePU(2),
    ("TwoTerminalVSCLine", "power_factor_setpoint_from") => Natural(),
    ("TwoTerminalVSCLine", "rated_ac_voltage_from") => Natural(),
    ("TwoTerminalVSCLine", "rated_ac_voltage_to") => Natural(),
    ("TwoTerminalVSCLine", "power_factor_setpoint_to") => Natural(),
    ("TwoTerminalVSCLine", "dc_current") => Natural(),
    ("TwoTerminalVSCLine", "max_dc_current_from") => Natural(),
    ("TwoTerminalVSCLine", "max_dc_current_to") => Natural(),
    ("InterconnectingConverter", "dc_current") => Natural(),
    ("InterconnectingConverter", "max_dc_current") => Natural(),
    # TModelHVDCLine: "in p.u. (SYSTEM_BASE)".
    ("TModelHVDCLine", "r") => SystemBasePU(),
    # "Load-frequency damping parameter ... (MW/Hz)".
    ("Area", "load_response") => Natural(),
    # Bases are physical by definition.
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
        # `base_power_12`, `base_voltage_primary`, ...
        return Natural()
    end
    return UnknownStorage()
end

# ── PSY6 side ─────────────────────────────────────────────────────────────────────────────

"""Every value a unit discriminator can take, in the order a basis is preferred."""
const UNIT_BASES = (
    :COMPONENT_BASE, :NATURAL_UNITS, :COMPONENT_MVAR, :MWH, :MWMIN,
    :USABLE_VOLUME, :TOTAL_VOLUME, :HEAD, :ENERGY,
)

"""
Discriminators whose value is data the record already carries (a reservoir's
`level_data_type`), rather than a unit basis the updater chooses and writes.
"""
const DATA_DISCRIMINATORS = Set([:level_data_type])

"""Power-family units, in which a per-unit value is a multiple of a base MVA."""
const POWER_UNITS = Set(["MW", "MVA", "MVAr", "MWh", "MW/min", "MVA/min", "MVAr/min"])

"""
Physical units PSY5 commonly stored per unit. A field PSY6 declares in one of these, whose
PSY5 storage is not known, is reported instead of copied.
"""
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
The unit PSY6 declares for `field` of model `T`, and the discriminator value to write for it
(`discriminator => basis`), or `nothing` when the updater need not write one.

A field with a per-unit basis gets it: PSY5's device-base values already are per unit on the
component's `base_power`. A data discriminator (`level_data_type`) is read from `raw`. Any
other discriminator takes its first basis in a power unit (`FixedAdmittance.y` in MVAr).
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
        unit = isnothing(value) ? nothing : _declared_unit(T, field, Symbol(value))
        return (unit, nothing)
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

# ── Conversion ────────────────────────────────────────────────────────────────────────────

"""Bus voltage bases and arc endpoints of a PSY5 case, for impedance and voltage bases."""
struct BusIndex
    base_voltage::Dict{String, Float64}
    arcs::Dict{String, Tuple{String, String}}
end

BusIndex() = BusIndex(Dict{String, Float64}(), Dict{String, Tuple{String, String}}())

function BusIndex(components)
    index = BusIndex()
    for raw in components
        type_name = component_type(raw)
        kv = get(raw, "base_voltage", nothing)
        if type_name in ("ACBus", "DCBus") && !isnothing(kv) && kv > 0
            # A non-physical base (0) is no base: a field needing it is reported, not scaled
            # by zero.
            index.base_voltage[component_uuid(raw)] = Float64(kv)
        elseif type_name == "Arc"
            index.arcs[component_uuid(raw)] =
                (reference_uuid(raw["from"]), reference_uuid(raw["to"]))
        end
    end
    return index
end

"""What converting one component's fields needs: its PSY5 record and the bases around it."""
struct ComponentUnits
    psy5_type::String
    raw::AbstractDict
    component_base::Float64
    system_base::Float64
    buses::BusIndex
end

"""
The component's voltage base (kV), from its buses: an injector's `bus`, or a branch's `arc`.
The two ends of a branch share one base except across a transformer, whose impedances are
per unit and never converted here; where they differ, the `from` bus is used. `nothing` when
the component names no bus with a base voltage.
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
    return if isnothing(ends)
        nothing
    else
        get(units.buses.base_voltage, ends[end_index], nothing)
    end
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

"""Marks a value whose unit could not be established; see `convert_units`."""
struct UnverifiedUnit
    reason::String
end

"""
Marks a value whose PSY5 base is non-physical (a base voltage of 0 or less), so it has no
value in the unit PSY6 declares: a data problem in the source, reported as an invalid value.
"""
struct NonPhysicalBase
    reason::String
end

_base(::DeviceBasePU, units::ComponentUnits) = units.component_base
_base(::SystemBasePU, units::ComponentUnits) = units.system_base

"""
The factor taking a per-unit value on `base` MVA to `unit`, or `nothing` when `unit` is not
reachable from per unit with the bases at hand.
"""
function _per_unit_factor(unit::AbstractString, base::Real, units::ComponentUnits)
    if unit in POWER_UNITS
        return base
    elseif unit in ("ohm", "S", "kV")
        kv = voltage_base(units)
        if isnothing(kv)
            return nothing
        end
        z_base = kv^2 / base
        return unit == "ohm" ? z_base : unit == "S" ? 1 / z_base : kv
    end
    return nothing
end

"""
`value` (as PSY5 stored it) in the unit PSY6 declares, or an `UnverifiedUnit` when that cannot
be established. `unit` is `target_unit`'s, `nothing` for a field with no declared unit.
"""
convert_units(::Psy5Storage, ::Nothing, value, ::ComponentUnits) = value
convert_units(::Natural, ::AbstractString, value, ::ComponentUnits) = value

convert_units(storage::RelativeTo, ::AbstractString, value, units::ComponentUnits) =
    _relative(value, _lookup(units.raw, storage.path), storage)

_relative(value, reference::Real, storage::RelativeTo) =
    if reference > 0
        _scale(value, reference)
    else
        NonPhysicalBase("relative to $(join(storage.path, ".")) = $reference")
    end
_relative(_, ::Any, storage::RelativeTo) =
    UnverifiedUnit("relative to $(join(storage.path, ".")), which is missing")

convert_units(::PerHour, unit::AbstractString, value, ::ComponentUnits) =
    endswith(unit, "/s") ? _scale(value, 1 / 3600) : value

function convert_units(::NaturalPower, unit::AbstractString, value, units::ComponentUnits)
    if _is_per_unit(unit)
        return _scale(value, 1 / units.component_base)
    end
    return unit in POWER_UNITS ? value : UnverifiedUnit("no conversion from MW to $unit")
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
        # Per unit on the component's base, which PSY5's device base already is.
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
