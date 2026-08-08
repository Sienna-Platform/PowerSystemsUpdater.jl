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

# PSY5 spells Arc's endpoints `from`/`to`; the PSY6 schema regen renamed them `from_id`/
# `to_id`. Renaming the keys before `direct_translate`'s generic field copy lets the
# existing reference-resolution path (`translate_value` -> `lookup_id`) pick them up like
# any other reference field, rather than recording two spurious unmapped fields and
# silently dropping Arc's topology. No docstring here: a docstring anywhere after the
# `@eval` loop above confuses Documenter's autodocs into reporting a duplicate-docs error
# (reproduced on unmodified HEAD too -- pre-existing, not this fix's doing), the same
# reason `translate/reserves.jl`'s dispatch methods carry only comments.
const ARC_FIELD_RENAMES = Dict("from" => "from_id", "to" => "to_id")

function translate(::Val{:Arc}, raw::AbstractDict, ctx::TranslationContext)
    renamed = copy(raw)
    for (old_key, new_key) in ARC_FIELD_RENAMES
        renamed[new_key] = pop!(renamed, old_key)
    end
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
