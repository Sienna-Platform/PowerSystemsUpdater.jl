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
    :FixedAdmittance, :HybridSystem, :HydroDispatch, :HydroPumpTurbine,
    :HydroTurbine, :InterconnectingConverter, :InterruptiblePowerLoad, :Line, :LoadZone,
    :MonitoredLine, :PowerLoad, :RenewableDispatch, :RenewableNonDispatch, :Source,
    :StandardLoad, :SynchronousCondenser, :ThermalMultiStart, :ThermalStandard,
    :TModelHVDCLine, :TwoTerminalGenericHVDCLine, :TwoTerminalLCCLine,
    :TwoTerminalVSCLine,
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
        return OpenAPI.APIModel[]
    end
    return translate(Val(Symbol(type_name)), raw, ctx)
end

"""
Fallback for a PSY5 type with no PSY6 counterpart: skip, record, continue.
"""
function translate(::Val{S}, raw::AbstractDict, ctx::TranslationContext) where {S}
    record_unmapped_type!(ctx.report, string(S))
    mark_skipped!(ctx.ledger, component_uuid(raw), "no PSY6 model for $(S)")
    return OpenAPI.APIModel[]
end

"""
Build a single PSY6 model of type `T` by copying fields by name.
"""
function direct_translate(
    ::Type{T},
    raw::AbstractDict,
    ctx::TranslationContext,
) where {T <: OpenAPI.APIModel}
    id = lookup_id(ctx.ledger, component_uuid(raw))
    extra = Dict{Symbol, Any}(:id => id)
    if :base_power in fieldnames(T)
        extra[:base_power] = base_power_for(raw, ctx.system_base)
    end
    kwargs = build_kwargs(T, raw, ctx.ledger, ctx.report; extra = extra)
    return OpenAPI.APIModel[T(; kwargs...)]
end

for name in DIRECT_TYPES
    @eval function translate(
        ::Val{$(QuoteNode(name))},
        raw::AbstractDict,
        ctx::TranslationContext,
    )
        return direct_translate(POM.$(name), raw, ctx)
    end
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
    return direct_translate(POM.Arc, renamed, ctx)
end

const TRANSLATED_TYPES = Set(
    vcat(
        String.(collect(DIRECT_TYPES)),
        [
            "Arc", "ConstantReserve", "VariableReserve",
            "Transformer2W", "TapTransformer", "PhaseShiftingTransformer",
            "Transformer3W", "HydroReservoir",
        ],
    ),
)

has_translator(type_name::AbstractString) = String(type_name) in TRANSLATED_TYPES
