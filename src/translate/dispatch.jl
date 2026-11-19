struct TranslationContext
    ledger::Ledger
    report::ConversionReport
    system_base::Float64
    buses::BusIndex
end

TranslationContext(ledger::Ledger, report::ConversionReport, system_base::Real) =
    TranslationContext(ledger, report, Float64(system_base), BusIndex())

"""The PSY6 id of the `ACBus` numbered `number`; `context` names the field in the error."""
function bus_id_for_number(
    ctx::TranslationContext,
    number::Integer,
    context::AbstractString,
)
    if !haskey(ctx.buses.uuid_by_number, Int(number))
        throw(Psy5FormatError("$context: no ACBus has number $number"))
    end
    return lookup_id(ctx.ledger, ctx.buses.uuid_by_number[Int(number)])
end

"""The number of the PSY5 `ACBus` whose UUID is `uuid`."""
function bus_number(ctx::TranslationContext, uuid::AbstractString)
    if !haskey(ctx.buses.number_by_uuid, uuid)
        throw(Psy5FormatError("no ACBus has UUID $uuid"))
    end
    return ctx.buses.number_by_uuid[uuid]
end

"""
Record `setpoint` as the `voltage_setpoint` of bus `bus_uuid`, for
`_apply_bus_voltage_setpoints`. PSY6 has one setpoint per bus: a second, different one is
reported as an approximate mapping and the first kept.
"""
function record_bus_voltage_setpoint!(
    ctx::TranslationContext,
    bus_uuid::AbstractString,
    setpoint::Real,
    source::AbstractString,
)
    setpoints = ctx.ledger.bus_voltage_setpoints
    if haskey(setpoints, bus_uuid) && !isapprox(setpoints[bus_uuid], setpoint)
        record_approximate_mapping!(ctx.report, "ACBus", "voltage_setpoint")
        @warn "ACBus $(bus_number(ctx, bus_uuid)): $source sets voltage_setpoint $setpoint, " *
              "but $(setpoints[bus_uuid]) is already set; keeping the first"
        return nothing
    end
    setpoints[String(bus_uuid)] = Float64(setpoint)
    return nothing
end

"""The bases `convert_units` needs for `raw`."""
component_units(raw::AbstractDict, ctx::TranslationContext) = ComponentUnits(
    component_type(raw),
    raw,
    base_power_for(raw, ctx.system_base),
    ctx.system_base,
    ctx.buses,
)

"""PSY5 fields PSY6 spells differently: `(PSY5 type, PSY5 field) => PSY6 field`."""
const PSY5_FIELD_RENAMES = Dict{Tuple{String, String}, String}(
    ("Source", "R_th") => "r_th",
    ("Source", "X_th") => "x_th",
)

"""
Rewrite PSY5 fields into the different PSY6 fields that carry the same information. Each
consumes the PSY5 field it maps; one that cannot be mapped is left for the copy to report.
"""
_derive_fields(::Type{T}, raw::AbstractDict, ctx::TranslationContext) where {T} =
    _derive_minimum_energy_offer(_derive_commitment_mode(T, raw), ctx)

"""PSY5 `must_run = true` is `commitment_mode = MUST_RUN`; `false` is PSY6's default."""
function _derive_commitment_mode(::Type{T}, raw::AbstractDict) where {T}
    if !haskey(raw, "must_run") || !(:commitment_mode in fieldnames(T))
        return raw
    end
    derived = copy(raw)
    if pop!(derived, "must_run") === true
        derived["commitment_mode"] = "MUST_RUN"
    end
    return derived
end

_market_bid_no_load_cost(cost::AbstractDict) =
    if _psy5_type_name(cost) == "MarketBidCost" &&
       isnothing(get(cost, "minimum_energy_offer", nothing))
        _real_or_nothing(get(cost, "no_load_cost", nothing))
    else
        nothing
    end
_market_bid_no_load_cost(::Any) = nothing

_real_or_nothing(value::Real) = Float64(value)
_real_or_nothing(::Any) = nothing

_min_of(limits::AbstractDict) = _real_or_nothing(get(limits, "min", nothing))
_min_of(::Any) = nothing

"""
PSY5 `MarketBidCost.no_load_cost` (\$/h) is PSY6 `minimum_energy_offer` (\$/MWh at minimum
power): `no_load_cost / P_min`, with P_min the device's `active_power_limits.min` in MW. With
no positive P_min the cost is left for the copy to report.
"""
function _derive_minimum_energy_offer(raw::AbstractDict, ctx::TranslationContext)
    cost = get(raw, "operation_cost", nothing)
    no_load = _market_bid_no_load_cost(cost)
    min_pu = _min_of(get(raw, "active_power_limits", nothing))
    if isnothing(no_load) || isnothing(min_pu) || min_pu <= 0
        return raw
    end
    p_min = min_pu * base_power_for(raw, ctx.system_base)
    offer = Dict{String, Any}(cost)
    delete!(offer, "no_load_cost")
    offer["minimum_energy_offer"] = _promote_market_bid_cost_scalar(no_load / p_min)
    derived = copy(raw)
    derived["operation_cost"] = offer
    return derived
end

function _rename_fields(raw::AbstractDict)
    type_name = component_type(raw)
    renamed = raw
    for (key, value) in raw
        target = get(PSY5_FIELD_RENAMES, (type_name, key), nothing)
        if !isnothing(target)
            if renamed === raw
                renamed = copy(raw)
            end
            delete!(renamed, key)
            renamed[target] = value
        end
    end
    return renamed
end

"""PSY5 types that map onto an identically named PSY6 model by a plain field copy."""
const DIRECT_TYPES = (
    :ACBus, :Area, :AreaInterchange, :DCBus, :DiscreteControlledACBranch,
    :EnergyReservoirStorage, :FACTSControlDevice, :HybridSystem, :HydroDispatch,
    :HydroTurbine, :InterruptiblePowerLoad, :InterruptibleStandardLoad, :Line,
    :LoadZone,
    :MotorLoad, :PowerLoad, :RenewableDispatch, :RenewableNonDispatch,
    :Source, :StandardLoad, :SynchronousCondenser, :ThermalMultiStart, :ThermalStandard,
)

"""
Translate one PSY5 component into zero or more PSY6 models. Zero models means it was
skipped, and the reason is already on the report and the ledger.
"""
function translate_component(raw::AbstractDict, ctx::TranslationContext)
    type_name = component_type(raw)
    if !has_translator(type_name)
        return translate(Val(Symbol(type_name)), raw, ctx)
    end
    uuid = component_uuid(raw)
    if references_skipped(raw, ctx.ledger)
        mark_skipped!(ctx.ledger, uuid, "references a skipped component")
        record_cascaded_skip!(ctx.report, type_name)
        return ICOM.APIModel[]
    end
    ctx.ledger.owner = uuid
    try
        return translate(Val(Symbol(type_name)), raw, ctx)
    finally
        ctx.ledger.owner = nothing
    end
end

"""Fallback for a PSY5 type with no PSY6 counterpart: skip and record."""
function translate(::Val{S}, raw::AbstractDict, ctx::TranslationContext) where {S}
    record_unmapped_type!(ctx.report, string(S))
    mark_skipped!(ctx.ledger, component_uuid(raw), "no PSY6 model for $(S)")
    return ICOM.APIModel[]
end

"""Build one PSY6 model of type `T` by copying `raw`'s fields by name."""
function direct_translate(
    ::Type{T},
    raw::AbstractDict,
    ctx::TranslationContext,
) where {T <: ICOM.APIModel}
    id = lookup_id(ctx.ledger, component_uuid(raw))
    extra = Dict{Symbol, Any}(:id => id)
    if :base_power in fieldnames(T)
        extra[:base_power] = base_power_for(raw, ctx.system_base)
    end
    if :power_units in fieldnames(T)
        extra[:power_units] = "COMPONENT_BASE"
    end
    renamed = _derive_fields(T, _rename_fields(raw), ctx)
    kwargs = build_kwargs(
        T,
        renamed,
        ctx.ledger,
        ctx.report;
        extra = extra,
        units = component_units(renamed, ctx),
    )
    return ICOM.APIModel[T(; kwargs...)]
end

"""The OpenAPI model type named `name`, from whichever model package defines it."""
function openapi_type(name::Symbol)
    for mod in (PCOM, POOM, ITSOM, ICOM)
        if isdefined(mod, name)
            return getfield(mod, name)
        end
    end
    error("no OpenAPI model package defines $(name)")
end

for name in DIRECT_TYPES
    @eval function translate(
        ::Val{$(QuoteNode(name))},
        raw::AbstractDict,
        ctx::TranslationContext,
    )
        return direct_translate($(openapi_type(name)), raw, ctx)
    end
end

# PSY6 requires `base_current` (kA, informational) on TModelHVDCLine, PSY5 records no current
# base, and the schema gives no default, so this throws rather than invent one.
# `KNOWN_CONVERSION_GAPS` in test/test_corpus.jl lists the corpus systems this excludes.
function translate(::Val{:TModelHVDCLine}, raw::AbstractDict, ::TranslationContext)
    throw(
        Psy5FormatError(
            "TModelHVDCLine $(get(raw, "name", "<unnamed>")) has no base_current; PSY6 " *
            "requires one (informational only) and PSY5 records no current base",
        ),
    )
end

# PSY5 `from`/`to` are PSY6 `from_id`/`to_id`. No docstrings on the `translate` methods: after
# the `@eval` loop above they make Documenter report duplicate docs.
function translate(::Val{:Arc}, raw::AbstractDict, ctx::TranslationContext)
    renamed = copy(raw)
    renamed["from_id"] = pop!(renamed, "from")
    renamed["to_id"] = pop!(renamed, "to")
    return direct_translate(PCOM.Arc, renamed, ctx)
end

"""
PSY6 has no `MonitoredLine`: it is a `Line` with `operational_flow_limit` set. PSY5's
`flow_limits` holds one maximum per direction; each becomes that direction's max with a min of
`0.0`. The limits share `rating`'s base, so they are not scaled.
"""
function translate(::Val{:MonitoredLine}, raw::AbstractDict, ctx::TranslationContext)
    renamed = copy(raw)
    limits = pop!(renamed, "flow_limits")
    renamed["operational_flow_limit"] = Dict{String, Any}(
        "from_to_min" => 0.0,
        "from_to_max" => limits["from_to"],
        "to_from_min" => 0.0,
        "to_from_max" => limits["to_from"],
    )
    return direct_translate(openapi_type(:Line), renamed, ctx)
end

# The generated struct field is the lowercased `y`, so PSY5's `Y` would be reported unmapped.
function translate(::Val{:FixedAdmittance}, raw::AbstractDict, ctx::TranslationContext)
    renamed = copy(raw)
    renamed["y"] = pop!(renamed, "Y")
    return direct_translate(POOM.FixedAdmittance, renamed, ctx)
end

"""
The PSY6 field `admittance_limits` (PSS/E VSWLO/VSWHI) lands in, by control mode. `FIXED` and
`UNDEFINED` use neither, so their band is kept in ext.
"""
const SWITCHED_ADMITTANCE_LIMITS_FIELD = Dict{String, String}(
    "DISCRETE_VOLTAGE" => "voltage_limits",
    "CONTINUOUS_VOLTAGE" => "voltage_limits",
    "DISCRETE_REACTIVE_PLANT" => "reactive_power_range_limits",
    "DISCRETE_REACTIVE_VSC" => "reactive_power_range_limits",
    "DISCRETE_ADMITTANCE_REMOTE" => "reactive_power_range_limits",
    "DISCRETE_REACTIVE_FACTS" => "reactive_power_range_limits",
)

"""
PSY5 `SwitchedAdmittance`, mapped as PowerFlowFileParser's PSS/E reader maps the same record
(`PowerFlowFileParser.jl/src/openapi/shunt.jl`):

  - `Y` (BINIT) -> `solved_admittance`, its susceptance, unset when zero. A non-zero
    conductance has no PSY6 field, so `Y` is then kept in ext whole.
  - `initial_status` (per-block in-service flag) -> `number_engaged` (per-block step count).
  - `Y_increase` -> `y_increase`; `admittance_limits` -> the field of
    `SWITCHED_ADMITTANCE_LIMITS_FIELD`, else ext.
  - `regulated_bus_number` -> `remote_regulated_bus` (an id); 0 or the shunt's own bus is none.

Known inexact mappings are reported (`_warn_switched_admittance_approximations`).
"""
function translate(::Val{:SwitchedAdmittance}, raw::AbstractDict, ctx::TranslationContext)
    _warn_switched_admittance_approximations(raw, ctx)
    renamed = copy(raw)
    y = pop!(renamed, "Y")
    if !iszero(y["real"])
        @warn "SwitchedAdmittance \"$(raw["name"])\": conductance real(Y) = $(y["real"]) " *
              "has no PSY6 field; Y is kept in ext"
        renamed["Y"] = y
    end
    if !iszero(y["imag"])
        renamed["solved_admittance"] = y["imag"]
    end
    if haskey(renamed, "initial_status")
        renamed["number_engaged"] = pop!(renamed, "initial_status")
    end
    renamed["y_increase"] = pop!(renamed, "Y_increase")
    regulated_number = pop!(renamed, "regulated_bus_number", 0)
    if !iszero(regulated_number) &&
       regulated_number != bus_number(ctx, reference_uuid(raw["bus"]))
        renamed["remote_regulated_bus"] = bus_id_for_number(
            ctx,
            regulated_number,
            "SwitchedAdmittance \"$(raw["name"])\" regulated_bus_number",
        )
    end
    limits_field =
        get(SWITCHED_ADMITTANCE_LIMITS_FIELD, get(raw, "control_mode", "FIXED"), nothing)
    if !isnothing(limits_field)
        renamed[limits_field] = pop!(renamed, "admittance_limits")
    end
    return direct_translate(POOM.SwitchedAdmittance, renamed, ctx)
end

"""
Report and log the `SwitchedAdmittance`s the mapping does not reproduce:

  - `solved_admittance`: `Y` is non-zero and a block is in service. PSY5 takes
    `Y + Σ initial_status · Y_increase`; PSY6 takes `Y` alone.
  - `number_engaged`: an in-service block has several steps, but `initial_status` does not say
    how many are engaged.
"""
function _warn_switched_admittance_approximations(
    raw::AbstractDict,
    ctx::TranslationContext,
)
    name = raw["name"]
    status = something(get(raw, "initial_status", nothing), Int[])
    steps = something(get(raw, "number_of_steps", nothing), Int[])
    if !iszero(raw["Y"]["imag"]) && any(>(0), status)
        record_approximate_mapping!(ctx.report, "SwitchedAdmittance", "solved_admittance")
        @warn "SwitchedAdmittance \"$name\": PSY5 adds the in-service blocks to Y " *
              "(Y + Σ initial_status · Y_increase); PSY6 uses solved_admittance = Y alone, " *
              "so the effective admittance differs"
    end
    if any(i -> status[i] > 0 && get(steps, i, 0) > 1, eachindex(status))
        record_approximate_mapping!(ctx.report, "SwitchedAdmittance", "number_engaged")
        @warn "SwitchedAdmittance \"$name\": initial_status is a per-block in-service " *
              "flag; written as number_engaged, a step count, for a block with several steps"
    end
    return nothing
end

# PSY5 stores loss coefficients as a bare curve; PSY6 wraps it in a `LossCurve` with the
# schema's natural-units `power_units`. The field name varies by type. The curve itself is
# left for `build_kwargs` to translate once.
const LOSS_CURVE_FIELDS =
    Set(["loss", "loss_function", "converter_loss_from", "converter_loss_to"])

function _wrap_loss_curves(raw::AbstractDict)
    renamed = raw
    for field in LOSS_CURVE_FIELDS
        value = get(raw, field, nothing)
        if !isnothing(value)
            if renamed === raw
                renamed = copy(raw)
            end
            renamed[field] =
                Dict{String, Any}("power_units" => "NATURAL_UNITS", "value_curve" => value)
        end
    end
    return renamed
end

"""
PSY6 requires a `rating` on the generic and LCC HVDC lines. PSY5 has none, so it is
`active_power_limits_from.max` (same base). `active_power_limits_from` stays for `build_kwargs`
to report as dropped: its `min` and the `_to` limits have no PSY6 field.
"""
function _with_rating_from_limits(raw::AbstractDict)
    limits = get(raw, "active_power_limits_from", nothing)
    if isnothing(limits)
        throw(
            Psy5FormatError(
                "$(component_type(raw)) $(get(raw, "name", "")) has no " *
                "active_power_limits_from to take the PSY6 rating from",
            ),
        )
    end
    rated = copy(raw)
    rated["rating"] = limits["max"]
    return rated
end

function translate(
    ::Val{:TwoTerminalGenericHVDCLine},
    raw::AbstractDict,
    ctx::TranslationContext,
)
    rated = _with_rating_from_limits(raw)
    return direct_translate(
        openapi_type(:TwoTerminalGenericHVDCLine),
        _wrap_loss_curves(rated),
        ctx,
    )
end

"""
PSY5 LCC `power_mode` and `transfer_setpoint` become PSY6 `control_mode` and one setpoint:
`POWER` with `power_transfer_setpoint` (MW), or `CURRENT` with `current_transfer_setpoint` (A).
"""
function _lcc_control(raw::AbstractDict)
    mode = get(raw, "power_mode", nothing)
    if isnothing(mode)
        return raw
    end
    derived = copy(raw)
    delete!(derived, "power_mode")
    setpoint = pop!(derived, "transfer_setpoint", nothing)
    derived["control_mode"] = mode ? "POWER" : "CURRENT"
    derived[mode ? "power_transfer_setpoint" : "current_transfer_setpoint"] = setpoint
    return derived
end

function translate(::Val{:TwoTerminalLCCLine}, raw::AbstractDict, ctx::TranslationContext)
    derived = _lcc_control(_with_rating_from_limits(raw))
    return direct_translate(
        openapi_type(:TwoTerminalLCCLine),
        _wrap_loss_curves(derived),
        ctx,
    )
end

"""
PSY5 VSC `dc_setpoint_*` and `ac_setpoint_*` hold whichever quantity the control mode
regulates; PSY6 has one field per quantity. An `AC_VOLTAGE` setpoint is instead the regulated
bus's `voltage_setpoint` (`_vsc_ac_voltage!`).
"""
const VSC_SETPOINT_FIELDS = (
    (
        "dc_setpoint",
        "dc_control",
        Dict(
            "DC_POWER" => "dc_power_setpoint",
            "DC_VOLTAGE" => "dc_voltage_setpoint",
            "DC_VOLTAGE_DROOP" => "dc_voltage_setpoint",
        ),
    ),
    (
        "ac_setpoint",
        "ac_control",
        Dict("AC_REACTIVE_POWER" => "power_factor_setpoint"),
    ),
)

"""The end of a VSC line's arc each side's converter sits at."""
const VSC_SIDE_END = Dict("from" => 1, "to" => 2)

"""
Move one `AC_VOLTAGE` converter end of a PSY5 VSC line onto `derived` in PSY6's form. PSY5
names the regulated bus by number (`remote_bus_control_<side>`, 0 for its own terminal) with
the target in `ac_setpoint_<side>`; PSY6 names a remote bus by id
(`remote_regulated_bus_<side>`) and keeps the target on that bus
(`_apply_bus_voltage_setpoints`).

A remote bus number that no `ACBus` has is a dangling source reference: the number and
setpoint are kept in ext and reported as dropped invalid values.
"""
function _vsc_ac_voltage!(
    derived::AbstractDict,
    raw::AbstractDict,
    side::AbstractString,
    ctx::TranslationContext,
)
    name = get(raw, "name", "<unnamed>")
    ends = ctx.buses.arcs[reference_uuid(raw["arc"])]
    terminal_uuid = ends[VSC_SIDE_END[side]]
    regulated_uuid = terminal_uuid
    remote = pop!(derived, "remote_bus_control_$side", 0)
    if !iszero(remote) && !haskey(ctx.buses.uuid_by_number, Int(remote))
        for field in ("remote_bus_control_$side", "ac_setpoint_$side")
            record_dropped_invalid_value!(ctx.report, "TwoTerminalVSCLine", field)
            keep_unmapped!(ctx.ledger, field, get(raw, field, nothing))
        end
        delete!(derived, "ac_setpoint_$side")
        return derived
    end
    if !iszero(remote) && remote != bus_number(ctx, terminal_uuid)
        derived["remote_regulated_bus_$side"] = bus_id_for_number(
            ctx,
            remote,
            "TwoTerminalVSCLine \"$name\" remote_bus_control_$side",
        )
        regulated_uuid = ctx.buses.uuid_by_number[Int(remote)]
    end
    record_bus_voltage_setpoint!(
        ctx,
        regulated_uuid,
        pop!(derived, "ac_setpoint_$side"),
        "TwoTerminalVSCLine \"$name\" ($side)",
    )
    return derived
end

function _vsc_setpoints(raw::AbstractDict, ctx::TranslationContext)
    derived = copy(raw)
    for side in ("from", "to")
        if get(raw, "ac_control_$side", nothing) == "AC_VOLTAGE"
            _vsc_ac_voltage!(derived, raw, side, ctx)
        elseif get(derived, "remote_bus_control_$side", nothing) == 0
            # Remote bus 0 means the own terminal; any other remote bus outside AC_VOLTAGE has
            # no PSY6 use and stays for the copy to report.
            delete!(derived, "remote_bus_control_$side")
        end
    end
    for side in ("from", "to"), (setpoint, control, targets) in VSC_SETPOINT_FIELDS
        key = "$(setpoint)_$side"
        target = get(targets, string(get(raw, "$(control)_$side", "")), nothing)
        if haskey(derived, key) && !isnothing(target)
            derived["$(target)_$side"] = pop!(derived, key)
        end
    end
    return derived
end

function translate(::Val{:TwoTerminalVSCLine}, raw::AbstractDict, ctx::TranslationContext)
    derived = _vsc_setpoints(raw, ctx)
    return direct_translate(
        openapi_type(:TwoTerminalVSCLine),
        _wrap_loss_curves(derived),
        ctx,
    )
end

function translate(
    ::Val{:InterconnectingConverter},
    raw::AbstractDict,
    ctx::TranslationContext,
)
    return direct_translate(
        openapi_type(:InterconnectingConverter),
        _wrap_loss_curves(raw),
        ctx,
    )
end

# PSY5's pump/generate/idle `status` is PSY6's `operating_mode`; PSY6 `status` is the on/off
# state and keeps its schema default, since PSY5 has no such flag here.
function translate(::Val{:HydroPumpTurbine}, raw::AbstractDict, ctx::TranslationContext)
    renamed = copy(raw)
    if haskey(renamed, "status")
        renamed["operating_mode"] = pop!(renamed, "status")
    end
    return direct_translate(POOM.HydroPumpTurbine, renamed, ctx)
end

# PSY5's Greek `α`/`β` are PSY6's ASCII `alpha`/`beta`.
function translate(::Val{:ExponentialLoad}, raw::AbstractDict, ctx::TranslationContext)
    renamed = copy(raw)
    renamed["alpha"] = pop!(renamed, "α")
    renamed["beta"] = pop!(renamed, "β")
    return direct_translate(POOM.ExponentialLoad, renamed, ctx)
end

const TRANSLATED_TYPES = Set(
    vcat(
        String.(collect(DIRECT_TYPES)),
        [
            "Arc", "MonitoredLine", "ConstantReserve", "VariableReserve",
            "Transformer2W", "TapTransformer", "PhaseShiftingTransformer",
            "Transformer3W", "PhaseShiftingTransformer3W", "HydroReservoir",
            "ExponentialLoad", "FixedAdmittance", "SwitchedAdmittance",
            "TwoTerminalGenericHVDCLine", "TwoTerminalLCCLine", "TwoTerminalVSCLine",
            "InterconnectingConverter", "HydroPumpTurbine", "TModelHVDCLine",
        ],
    ),
)

has_translator(type_name::AbstractString) = String(type_name) in TRANSLATED_TYPES
