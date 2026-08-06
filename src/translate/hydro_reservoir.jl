"""
PSY6's `head_to_volume_factor` is a bare `FunctionData`; PSY5 wraps it one level deeper in
an `InputOutputCurve`. `input_at_zero` is `null` in every corpus occurrence, but a future
non-null value is recorded rather than assumed away.
"""
function _head_to_volume_factor(raw::AbstractDict, ctx::TranslationContext)
    curve = raw["head_to_volume_factor"]
    input_at_zero = get(curve, "input_at_zero", nothing)
    if !isnothing(input_at_zero)
        record_unmapped_field!(
            ctx.report,
            "HydroReservoir",
            "head_to_volume_factor.input_at_zero",
        )
    end
    return translate_value(curve["function_data"], ctx.ledger)
end

function translate(::Val{:HydroReservoir}, raw::AbstractDict, ctx::TranslationContext)
    id = lookup_id(ctx.ledger, component_uuid(raw))
    extra = Dict{Symbol, Any}(
        :id => id,
        :head_to_volume_factor => _head_to_volume_factor(raw, ctx),
    )
    kwargs = build_kwargs(POM.HydroReservoir, raw, ctx.ledger, ctx.report; extra = extra)
    return OpenAPI.APIModel[POM.HydroReservoir(; kwargs...)]
end
