struct TranslationContext
    ledger::Ledger
    report::ConversionReport
    system_base::Float64
end

"""
PSY5 type names that map onto an identically named PSY6 model. Everything else needs a
bespoke `translate` method.
"""
const DIRECT_TYPES = (
    :ACBus, :Area, :AreaInterchange, :DCBus, :EnergyReservoirStorage,
    :HybridSystem, :HydroDispatch,
    :HydroTurbine, :InterruptiblePowerLoad, :Line, :LoadZone,
    :MotorLoad, :PowerLoad, :RenewableDispatch, :RenewableNonDispatch,
    :Source, :StandardLoad, :SynchronousCondenser, :ThermalMultiStart, :ThermalStandard,
)

"""
Translate one PSY5 component into zero or more PSY6 models.

Zero models means the component was skipped; the reason is already recorded on the report
and the ledger.
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
    return translate(Val(Symbol(type_name)), raw, ctx)
end

"""
Fallback for a PSY5 type with no PSY6 counterpart: skip, record, continue.
"""
function translate(::Val{S}, raw::AbstractDict, ctx::TranslationContext) where {S}
    record_unmapped_type!(ctx.report, string(S))
    mark_skipped!(ctx.ledger, component_uuid(raw), "no PSY6 model for $(S)")
    return ICOM.APIModel[]
end

"""
Build a single PSY6 model of type `T` by copying fields by name.
"""
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
    kwargs = build_kwargs(T, raw, ctx.ledger, ctx.report; extra = extra)
    return ICOM.APIModel[T(; kwargs...)]
end

"""
The OpenAPI model type named `name`, from whichever model package defines it.
"""
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

# The cable exception, and the one type this translator cannot convert. PSY6 anchors
# TModelHVDCLine's per-unit `r`/`l`/`c` on a required `base_current` (A) and gives it no
# `base_power` at all; PSY5 records no current base anywhere on the type, and
# `Operations/Branch/TModelHVDCLine.json` documents no default to fall back on. Nothing here
# can be derived from the owning system either — the system base is a power, not a current.
# Stamping a placeholder would mis-scale every per-unit field on the cable with no error, so
# this throws instead. `KNOWN_CONVERSION_GAPS` in test/test_corpus.jl records the corpus
# systems this takes out.
function translate(::Val{:TModelHVDCLine}, raw::AbstractDict, ::TranslationContext)
    throw(
        Psy5FormatError(
            "TModelHVDCLine $(get(raw, "name", "<unnamed>")) has no base_current; PSY6 " *
            "requires one (A) to per-unitize r/l/c and PSY5 records no current base",
        ),
    )
end

# PSY5 spells Arc's endpoints `from`/`to`; PSY6 names them `from_id`/`to_id`. Renaming
# before `direct_translate`'s generic field copy routes them through the ordinary
# reference-resolution path (`translate_value` -> `lookup_id`) instead of recording two
# unmapped fields and dropping Arc's topology. No docstring here: any docstring after the
# `@eval` loop above makes Documenter's autodocs report a duplicate-docs error, the same
# reason `translate/reserves.jl`'s dispatch methods carry only comments.
function translate(::Val{:Arc}, raw::AbstractDict, ctx::TranslationContext)
    renamed = copy(raw)
    renamed["from_id"] = pop!(renamed, "from")
    renamed["to_id"] = pop!(renamed, "to")
    return direct_translate(PCOM.Arc, renamed, ctx)
end

"""
PSY6 has no `MonitoredLine`: it is a `Line` whose `operational_flow_limit` is set. PSY5's
`flow_limits` holds one maximum per direction, `(from_to, to_from)`; PSY6 holds a min/max pair
per direction, written flat in the document (`from_to_min`, `from_to_max`, ...). Each PSY5
value becomes that direction's max, and each min is `0.0`, reading the PSY5 limits as bounds
on the flow in each direction separately (the PSY6 field documents "minimum and maximum flow
in each direction"). The limits are on the same base as `rating`, so they carry across
unscaled, as `rating` does.
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

# PSY5 spells FixedAdmittance's admittance field `Y`; the PSY6 schema property is also `Y`,
# but the generated Julia struct field is the lowercased `y` (the generator lowercases an
# all-uppercase property name). `build_kwargs` matches PSY5 keys against `fieldnames(T)`, so
# the raw `Y` key never matches `:y` and is recorded as unmapped instead of filling the
# required field. Renaming before `direct_translate`'s generic field copy fixes that.
function translate(::Val{:FixedAdmittance}, raw::AbstractDict, ctx::TranslationContext)
    renamed = copy(raw)
    renamed["y"] = pop!(renamed, "Y")
    return direct_translate(POOM.FixedAdmittance, renamed, ctx)
end

# PSY5 stores a device's loss coefficients as a bare curve (`InputOutputCurve` or
# `IncrementalCurve`); PSY6 wraps it in a `LossCurve` (`power_units` + `value_curve`). PSY5
# has no field for `power_units` here — the natural-units default the schema documents. The
# field carrying it is spelled differently per type (`loss` on the two-terminal HVDC lines,
# `loss_function` on `InterconnectingConverter`, `converter_loss_from`/`converter_loss_to` on
# `TwoTerminalVSCLine`), so every known name is checked; no type declares more than one of
# them. Wrapping before `direct_translate`'s generic field copy leaves the curve itself
# untranslated so `build_kwargs`'s own call to `translate_value` on the wrapped dict gives it
# its discriminator exactly once, the same reasoning `_promote_market_bid_cost_scalar` follows.
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
PSY6 requires a `rating` (the DC line's transfer rating) on the generic and LCC HVDC lines,
which PSY5 does not record; PSY5 bounds the transfer with `active_power_limits_from` instead,
and PSY6 removed that field. The rating is taken as `active_power_limits_from.max`, on the same
base, so it carries across unscaled. `active_power_limits_from` itself is left in place for
`build_kwargs` to report as dropped: its `min`, and the `_to` limits, have no PSY6 home.
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

for name in (:TwoTerminalGenericHVDCLine, :TwoTerminalLCCLine)
    @eval function translate(
        ::Val{$(QuoteNode(name))},
        raw::AbstractDict,
        ctx::TranslationContext,
    )
        rated = _with_rating_from_limits(raw)
        return direct_translate($(openapi_type(name)), _wrap_loss_curves(rated), ctx)
    end
end

for name in (:TwoTerminalVSCLine, :InterconnectingConverter)
    @eval function translate(
        ::Val{$(QuoteNode(name))},
        raw::AbstractDict,
        ctx::TranslationContext,
    )
        return direct_translate($(openapi_type(name)), _wrap_loss_curves(raw), ctx)
    end
end

# PSY5 spells the pumped-storage unit's pump/generate/idle mode `status`
# (`"PUMP"`/`"GEN"`/`"OFF"`); PSY6 calls that field `operating_mode` and reserves `status` for
# the ordinary on/off `OperationalStates` every other committable device uses. Renaming
# before `direct_translate`'s generic field copy routes the PSY5 value onto its real PSY6
# field instead of failing `OperationalStates`' enum validation; PSY6 `status` is left unset
# and takes the schema's own `"OFFLINE"` default, since PSY5 has no separate on/off flag here.
function translate(::Val{:HydroPumpTurbine}, raw::AbstractDict, ctx::TranslationContext)
    renamed = copy(raw)
    if haskey(renamed, "status")
        renamed["operating_mode"] = pop!(renamed, "status")
    end
    return direct_translate(POOM.HydroPumpTurbine, renamed, ctx)
end

# PSY5 spells ExponentialLoad's voltage-dependency exponents with Greek letters `α`/`β`;
# PSY6 spells them ASCII `alpha`/`beta`. Renaming before `direct_translate`'s generic field
# copy routes them through the ordinary field-copy path instead of recording two unmapped
# fields and leaving the required alpha/beta absent.
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
            "Transformer3W", "HydroReservoir", "ExponentialLoad", "FixedAdmittance",
            "TwoTerminalGenericHVDCLine", "TwoTerminalLCCLine", "TwoTerminalVSCLine",
            "InterconnectingConverter", "HydroPumpTurbine", "TModelHVDCLine",
        ],
    ),
)

has_translator(type_name::AbstractString) = String(type_name) in TRANSLATED_TYPES
