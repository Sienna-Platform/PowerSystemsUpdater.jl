"""
PSY5 keys that never become PSY6 properties. `services` is absent from the schemas by
convention; `ext` is routed through `set_ext!` rather than a field; `internal` and
`__metadata__` are serialization scaffolding.
"""
const PSY5_INTERNAL_FIELDS = Set(["__metadata__", "internal", "services", "ext"])

struct SkippedReferenceSignal <: Exception
    msg::String
end

Base.showerror(io::IO, e::SkippedReferenceSignal) =
    print(io, "SkippedReferenceSignal: ", e.msg)

"""
PSY5 type name -> (PSY6 discriminator property, discriminator value). PSY5 has no such
field; the value comes from `__metadata__.type`, not a formula on the name.
"""
const ONEOF_DISCRIMINATORS = Dict{String, Tuple{Symbol, String}}(
    "CostCurve" => (:variable_cost_type, "COST"),
    "FuelCurve" => (:variable_cost_type, "FUEL"),
    "InputOutputCurve" => (:curve_type, "INPUT_OUTPUT"),
    "IncrementalCurve" => (:curve_type, "INCREMENTAL"),
    "AverageRateCurve" => (:curve_type, "AVERAGE_RATE"),
    "LinearFunctionData" => (:function_type, "LINEAR"),
    "QuadraticFunctionData" => (:function_type, "QUADRATIC"),
    "PiecewiseLinearData" => (:function_type, "PIECEWISE_LINEAR"),
    "PiecewiseStepData" => (:function_type, "PIECEWISE_STEP"),
    "RenewableGenerationCost" => (:cost_type, "RENEWABLE"),
    "ThermalGenerationCost" => (:cost_type, "THERMAL"),
    "HydroGenerationCost" => (:cost_type, "HYDRO_GEN"),
    "StorageCost" => (:cost_type, "STORAGE"),
)

function _psy5_type_name(dict::AbstractDict)
    metadata = get(dict, "__metadata__", nothing)
    if isnothing(metadata)
        return nothing
    end
    return get(metadata, "type", nothing)
end

"""
`StartUpStages` carries no `__metadata__` tag in PSY5, so it is detected by its unique
key set instead, the same way `is_reference` classifies by shape rather than by tag.
"""
_is_start_up_stages_shape(dict::AbstractDict) =
    Set(keys(dict)) == Set(("hot", "warm", "cold"))

translate_value(value, ::Ledger, ::ConversionReport) = value

"""
Record every key on a resolved nested composite (`type_name` from `__metadata__.type`, or
`"StartUpStages"` for the untagged shape) that is not one of `PCOM.model_type(type_name)`'s
fieldnames — the nested analogue of `build_kwargs`'s unmapped-field guard.

Only fires when `type_name` resolves to a registered PSY6 model; an unresolved nested dict
(no `__metadata__.type`, or a PSY5 type with no PSY6 counterpart) is forwarded unchanged, as
before, with nothing to check its keys against. `__metadata__` itself is never flagged: the
schemas allow the extra key.
"""
function _record_unmapped_nested_fields!(
    translated::AbstractDict,
    type_name::Union{Nothing, AbstractString},
    report::ConversionReport,
)
    if isnothing(type_name) || !PCOM.has_model_type(type_name)
        return nothing
    end
    targets = Set(fieldnames(PCOM.model_type(type_name)))
    for key in keys(translated)
        if key == "__metadata__"
            continue
        end
        if !(Symbol(key) in targets)
            record_unmapped_field!(report, type_name, key)
        end
    end
    return nothing
end

"""
Non-reference dicts are forwarded recursively rather than verbatim, so a nested `oneOf`
(a `CostCurve` containing a `ValueCurve` containing `FunctionData`) gets its discriminator
at every level in one pass. `__metadata__` is left in place: the schemas allow the extra key.

Every resolved nested composite is also checked against its PSY6 fieldnames
(`_record_unmapped_nested_fields!`), the same guard `build_kwargs` applies at the top level —
otherwise a PSY5 field with no PSY6 counterpart inside a nested object (for example
`FuelCurve.startup_fuel_offtake`) would be forwarded into the output silently instead of
being recorded as a finding.
"""
function translate_value(value::AbstractDict, ledger::Ledger, report::ConversionReport)
    if is_reference(value)
        return lookup_id(ledger, reference_uuid(value))
    end
    translated = Dict{String, Any}(
        key => translate_value(v, ledger, report) for (key, v) in value
    )
    type_name = _psy5_type_name(translated)
    if !isnothing(type_name) && haskey(ONEOF_DISCRIMINATORS, type_name)
        property, discriminator_value = ONEOF_DISCRIMINATORS[type_name]
        translated[string(property)] = discriminator_value
    elseif isnothing(type_name) && _is_start_up_stages_shape(translated)
        type_name = "StartUpStages"
        translated["startup_stages_type"] = "STAGES"
    end
    _record_unmapped_nested_fields!(translated, type_name, report)
    return translated
end

function translate_value(value::AbstractVector, ledger::Ledger, report::ConversionReport)
    return [translate_value(v, ledger, report) for v in value]
end

"""
True when any reference on `raw` points at a component that was skipped. Such a component
must itself be skipped: `validate_document` does not check ordinary component references,
so a dangling integer would otherwise reach the output.
"""
function references_skipped(raw::AbstractDict, ledger::Ledger)
    for (key, value) in raw
        if key in PSY5_INTERNAL_FIELDS
            continue
        end
        if _points_at_skipped(value, ledger)
            return true
        end
    end
    return false
end

_points_at_skipped(::Any, ::Ledger) = false

function _points_at_skipped(value::AbstractDict, ledger::Ledger)
    if is_reference(value)
        return is_skipped(ledger, reference_uuid(value))
    end
    return false
end

function _points_at_skipped(value::AbstractVector, ledger::Ledger)
    return any(v -> _points_at_skipped(v, ledger), value)
end

"""
Build the keyword arguments for `T` from a PSY5 component dict.

Copies by name for every field `T` declares, resolving UUID references to integer ids.
Values are never rescaled. PSY5 keys with no counterpart on `T` are recorded on `report`
rather than dropped silently — an unmapped field is a finding about the schemas.
"""
function build_kwargs(
    ::Type{T},
    raw::AbstractDict,
    ledger::Ledger,
    report::ConversionReport;
    extra::AbstractDict = Dict{Symbol, Any}(),
) where {T <: OpenAPI.APIModel}
    targets = Set(fieldnames(T))
    kwargs = Dict{Symbol, Any}()
    type_name = component_type(raw)
    for (key, value) in raw
        if key in PSY5_INTERNAL_FIELDS
            continue
        end
        symbol = Symbol(key)
        if !(symbol in targets)
            record_unmapped_field!(report, type_name, key)
            continue
        end
        if isnothing(value)
            continue
        end
        kwargs[symbol] = translate_value(value, ledger, report)
    end
    for (key, value) in extra
        kwargs[key] = value
    end
    return kwargs
end
