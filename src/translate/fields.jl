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
PSY5 type name -> (PSY6 discriminator property, discriminator value), for every PSY6
`oneOf` union this package's translators can reach. Reverse-engineered from each union's
generated `OpenAPI.property_type` method in PowerCoreOpenAPIModels: PSY5 has no equivalent
field, and the value has no derivable relationship to the PSY5 type name (`CostCurve` ->
`"COST"`), so this is a literal table, not a formula — in the spirit of
`WINDING_GROUP_ALPHA`.

Two different unions can discriminate on the same property name for the same PSY5 type
(`ValueCurve` and `TwoTerminalLoss` both read `curve_type` off `InputOutputCurve`; `FunctionData`
and its three curve-scoped variants all read `function_type` off `LinearFunctionData`), and in
every such case the value they expect is identical — confirmed both against every
`property_type` method in `PowerCoreOpenAPIModels` and against the `oneOf`/`discriminator`
blocks in `SiennaSchemas/Core/common.json` directly — so one PSY5-type-keyed table serves all
of them unambiguously.

`SiennaSchemas` sets `additionalProperties: false` nowhere on `CostCurve`, `FuelCurve`,
`ProductionVariableCostCurve`, `ValueCurve`, `FunctionData`, or any of their branches
(confirmed by grepping `SiennaSchemas/Core/*.json` for the key), so leaving PSY5's
`__metadata__` in place alongside the injected discriminator is schema-legal, not merely
untested.
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
`ThermalGenerationCost.start_up`'s `oneOf` (`Union{Float64, StartUpStages}`, discriminated by
`startup_stages_type`) is the one union in reach that PSY5 never tags with `__metadata__` at
all — it serializes a `StartUpStages` value as a bare `{"hot", "warm", "cold"}` dict,
indistinguishable from the untagged `MinMax`/`FromTo`/`UpDown`/`InOut` composites except by
its own key set. `is_reference` already classifies dicts by shape rather than by tag, so this
follows that precedent rather than inventing a new one; `{"hot", "warm", "cold"}` does not
collide with any other untagged composite this package recognizes. Found after the corpus
sweep hit `KeyError: key "startup_stages_type" not found` on `c_sys5_pglib` and
`c_sys5_uc_non_spin`; adding a metadata-tagged table entry (tried first) could not fix it,
since there is no tag to match on.
"""
_is_start_up_stages_shape(dict::AbstractDict) =
    Set(keys(dict)) == Set(("hot", "warm", "cold"))

translate_value(value, ::Ledger) = value

"""
Non-reference dicts are forwarded recursively, field by field, rather than verbatim: PSY5's
simple nested composites (`MinMax`, `FromTo`, `UpDown`, `InOut`) carry no `__metadata__` and
pass through unchanged, matched to PSY6 by field name (drift there is guarded by the canary
testset in test/test_translate_fields.jl, not checked here). But PSY6's `oneOf`-typed nested
objects (cost curves, value curves, function data, ...) need a discriminator property PSY5
never had; `ONEOF_DISCRIMINATORS` supplies it for every PSY5 type this package recognizes, and
recursion is required because these nest (a `CostCurve` contains a `ValueCurve` containing
`FunctionData`, and each of the three needs its own discriminator). A PSY5 type not in the
table is forwarded unchanged, exactly as before this existed.

`__metadata__` itself is left in the output rather than stripped: the schemas do not set
`additionalProperties: false`, so the extra key is tolerated, and stripping it would be a
second, unrequested behavior change bundled into this fix.
"""
function translate_value(value::AbstractDict, ledger::Ledger)
    if is_reference(value)
        return lookup_id(ledger, reference_uuid(value))
    end
    translated =
        Dict{String, Any}(key => translate_value(v, ledger) for (key, v) in value)
    type_name = _psy5_type_name(translated)
    if !isnothing(type_name) && haskey(ONEOF_DISCRIMINATORS, type_name)
        property, discriminator_value = ONEOF_DISCRIMINATORS[type_name]
        translated[string(property)] = discriminator_value
    elseif isnothing(type_name) && _is_start_up_stages_shape(translated)
        translated["startup_stages_type"] = "STAGES"
    end
    return translated
end

function translate_value(value::AbstractVector, ledger::Ledger)
    return [translate_value(v, ledger) for v in value]
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
        kwargs[symbol] = translate_value(value, ledger)
    end
    for (key, value) in extra
        kwargs[key] = value
    end
    return kwargs
end
