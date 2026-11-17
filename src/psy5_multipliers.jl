# PSY5 stored a time series as a normalized profile plus the name of an owner accessor, the
# "scaling factor multiplier". PSY5 read the value as profile x accessor(owner). This file is the
# one place that states these PSY5 assumptions and computes the factor that PSY6 needs.
#
# A PSY5 JSON stores device fields on the device base, so a factor read from a raw device dict is
# already in CU. Owners with no `base_power` field store their fields on the system base.
#
# | PSY5 multiplier                                           | PSY5 meaning                          | PSY6 output                                                              | Factor                                    |
# |-----------------------------------------------------------|---------------------------------------|--------------------------------------------------------------------------|-------------------------------------------|
# | `get_max_active_power`                                    | value x owner max active power        | CU; `per_unit_of = "base_power"`, `quantity_kind = "ActivePower"`        | owner max active power (CU)               |
# | `get_max_reactive_power`                                  | value x owner max reactive power      | CU; `per_unit_of = "base_power"`, `quantity_kind = "ReactivePower"`      | owner max reactive power (CU)             |
# | `get_requirement`                                         | value x service requirement (SU)      | MW; `units = "MW"`, `quantity_kind = "ActivePower"`                      | `requirement` x system base               |
# | `get_peak_active_power`                                   | value x peak active power (SU)        | MW; `units = "MW"`, `quantity_kind = "ActivePower"`                      | `peak_active_power` x system base         |
# | `get_storage_capacity`, `get_storage_target`, `get_inflow`| depends on `level_data_type`          | values unchanged                                                         | 1.0                                       |
#
# A factor does not exist when the PSY5 accessor has no value (missing field, `null`, `Inf`, `NaN`).

abstract type Psy5Multiplier end

struct MaxActivePower <: Psy5Multiplier end
struct MaxReactivePower <: Psy5Multiplier end
struct Requirement <: Psy5Multiplier end
struct PeakActivePower <: Psy5Multiplier end
struct ReservoirMultiplier <: Psy5Multiplier end

const PSY5_MULTIPLIERS = Dict{String, Psy5Multiplier}(
    "get_max_active_power" => MaxActivePower(),
    "get_max_reactive_power" => MaxReactivePower(),
    "get_requirement" => Requirement(),
    "get_peak_active_power" => PeakActivePower(),
    "get_storage_capacity" => ReservoirMultiplier(),
    "get_storage_target" => ReservoirMultiplier(),
    "get_inflow" => ReservoirMultiplier(),
)

"""
Return the multiplier for a PSY5 accessor name. Throw `Psy5FormatError` for an unknown name.
"""
function psy5_multiplier(name::AbstractString)
    return get(PSY5_MULTIPLIERS, name) do
        throw(Psy5FormatError("unknown PSY5 scaling factor multiplier accessor: $name"))
    end
end

# Raw field readers. A field that is missing, `null`, or not finite gives `NaN`, and `NaN`
# propagates through the arithmetic of every rule.
_field(::Nothing) = NaN
_field(x::Real) = Float64(x)
_field(raw::AbstractDict, key::AbstractString) = _field(get(raw, key, nothing))

_limits_max(::Nothing) = NaN
_limits_max(limits::AbstractDict) = _field(limits, "max")
_limits_max(raw::AbstractDict, key::AbstractString) = _limits_max(get(raw, key, nothing))

_present(::Nothing) = false
_present(::Any) = true

function _field_or_limits_max(raw::AbstractDict, field::String, limits::String)
    if _present(get(raw, field, nothing))
        return _field(raw, field)
    end
    return _limits_max(raw, limits)
end

_renewable_active(raw::AbstractDict) = _field(raw, "rating") * _field(raw, "power_factor")

function _standard_load_active(raw::AbstractDict)
    return _field(raw, "max_constant_active_power") +
           _field(raw, "max_impedance_active_power") +
           _field(raw, "max_current_active_power")
end

function _generic_active(raw::AbstractDict)
    return _field_or_limits_max(raw, "max_active_power", "active_power_limits")
end

function _renewable_reactive(raw::AbstractDict)
    return _field(raw, "rating") * sin(acos(_field(raw, "power_factor")))
end

function _renewable_dispatch_reactive(raw::AbstractDict)
    if _present(get(raw, "reactive_power_limits", nothing))
        return _limits_max(raw, "reactive_power_limits")
    end
    return _renewable_reactive(raw)
end

function _generic_reactive(raw::AbstractDict)
    return _field_or_limits_max(raw, "max_reactive_power", "reactive_power_limits")
end

const MAX_ACTIVE_POWER_RULES = Dict{String, Function}(
    "RenewableDispatch" => _renewable_active,
    "RenewableNonDispatch" => _renewable_active,
    "StandardLoad" => _standard_load_active,
    "InterruptibleStandardLoad" => _standard_load_active,
)

const MAX_REACTIVE_POWER_RULES = Dict{String, Function}(
    "RenewableNonDispatch" => _renewable_reactive,
    "RenewableDispatch" => _renewable_dispatch_reactive,
)

function _factor(::MaxActivePower, raw::AbstractDict, ::Float64)
    return get(MAX_ACTIVE_POWER_RULES, component_type(raw), _generic_active)(raw)
end
function _factor(::MaxReactivePower, raw::AbstractDict, ::Float64)
    return get(MAX_REACTIVE_POWER_RULES, component_type(raw), _generic_reactive)(raw)
end
function _factor(::Requirement, raw::AbstractDict, system_base::Float64)
    return _field(raw, "requirement") * system_base
end
function _factor(::PeakActivePower, raw::AbstractDict, system_base::Float64)
    return _field(raw, "peak_active_power") * system_base
end
_factor(::ReservoirMultiplier, ::AbstractDict, ::Float64) = 1.0

"""
Return `true` when the PSY5 accessor of `m` has a finite value for the owner `raw`.
"""
function has_scale_factor(m::Psy5Multiplier, raw::AbstractDict, system_base::Float64)
    return isfinite(_factor(m, raw, system_base))
end

"""
Return the factor that converts a normalized PSY5 profile to PSY6 values. Throw
`Psy5FormatError` when the owner has no factor. `system_base` is the system base power in MVA.
"""
function scale_factor(m::Psy5Multiplier, raw::AbstractDict, system_base::Float64)
    factor = _factor(m, raw, system_base)
    if !isfinite(factor)
        throw(
            Psy5FormatError(
                "no scaling factor for multiplier $(nameof(typeof(m))) on " *
                "$(component_type(raw)) $(get(raw, "name", "<unnamed>"))",
            ),
        )
    end
    return factor
end

function store_labels(::MaxActivePower)
    return (units = nothing, quantity_kind = "ActivePower", per_unit_of = "base_power")
end
function store_labels(::MaxReactivePower)
    return (units = nothing, quantity_kind = "ReactivePower", per_unit_of = "base_power")
end
function store_labels(::Union{Requirement, PeakActivePower})
    return (units = "MW", quantity_kind = "ActivePower", per_unit_of = nothing)
end
