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

translate_value(value, ::Ledger) = value

function translate_value(value::AbstractDict, ledger::Ledger)
    if is_reference(value)
        return lookup_id(ledger, reference_uuid(value))
    end
    return value
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
