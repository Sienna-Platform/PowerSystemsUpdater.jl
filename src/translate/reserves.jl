"""
PSY5 carries reserve direction as a type parameter (`VariableReserve{ReserveUp}`); PSY6
carries it as a field with a different vocabulary.
"""
const RESERVE_DIRECTIONS = Dict(
    "ReserveUp" => "UP",
    "ReserveDown" => "DOWN",
    "ReserveSymmetric" => "SYMMETRIC",
)

function reserve_direction(raw::AbstractDict)
    parameters = component_parameters(raw)
    if length(parameters) != 1
        throw(
            Psy5FormatError(
                "expected exactly one reserve type parameter, got $(parameters)",
            ),
        )
    end
    parameter = parameters[1]
    if !haskey(RESERVE_DIRECTIONS, parameter)
        throw(Psy5FormatError("unknown reserve direction $parameter"))
    end
    return RESERVE_DIRECTIONS[parameter]
end

# ConstantReserve and VariableReserve have identical PSY5 field sets. Both become an
# OnlineReserve; whether the requirement is static or time-varying is carried by the
# presence of a `requirement` time series, not by a field.
function _translate_reserve(raw::AbstractDict, ctx::TranslationContext)
    id = lookup_id(ctx.ledger, component_uuid(raw))
    extra = Dict{Symbol, Any}(
        :id => id,
        :reserve_direction => reserve_direction(raw),
    )
    kwargs = build_kwargs(POM.OnlineReserve, raw, ctx.ledger, ctx.report; extra = extra)
    return OpenAPI.APIModel[POM.OnlineReserve(; kwargs...)]
end

function translate(::Val{:ConstantReserve}, raw::AbstractDict, ctx::TranslationContext)
    return _translate_reserve(raw, ctx)
end

function translate(::Val{:VariableReserve}, raw::AbstractDict, ctx::TranslationContext)
    return _translate_reserve(raw, ctx)
end
