struct DanglingReferenceError <: Exception
    msg::String
end

Base.showerror(io::IO, e::DanglingReferenceError) =
    print(io, "DanglingReferenceError: ", e.msg)

"""
Maps PSY5 component UUIDs onto the document-wide unique integer ids PSY6 requires, and
records components that were skipped so references to them can be detected rather than
emitted as dangling integers.

It also keeps, per component, the PSY5 values that have no PSY6 field (`unmapped`, keyed by
UUID), collected against `owner`, the component being translated (`translate_component`).
They are written to the component's `ext` (`_carry_ext!` in convert.jl) rather than dropped.
"""
mutable struct Ledger
    ids::Dict{String, Int}
    skipped::Dict{String, String}
    counter::Int
    owner::Union{Nothing, String}
    unmapped::Dict{String, Dict{String, Any}}
end

Ledger() = Ledger(
    Dict{String, Int}(),
    Dict{String, String}(),
    0,
    nothing,
    Dict{String, Dict{String, Any}}(),
)

"""
Assign an id to `uuid`, or return the one already assigned. Idempotent.
"""
function assign_id!(ledger::Ledger, uuid::AbstractString)
    key = String(uuid)
    if haskey(ledger.ids, key)
        return ledger.ids[key]
    end
    ledger.counter += 1
    ledger.ids[key] = ledger.counter
    return ledger.counter
end

"""
Reserve an id for a component that translation synthesizes and that has no PSY5 UUID —
transformer circuits, for instance.
"""
function allocate_id!(ledger::Ledger)
    ledger.counter += 1
    return ledger.counter
end

has_id(ledger::Ledger, uuid::AbstractString) = haskey(ledger.ids, String(uuid))

"""
Resolve `uuid` to its assigned id.

This is the single funnel every reference resolution passes through — `translate_value`
calls it at every nesting depth, not just the top level. Throwing here when `uuid` is
skipped is the backstop for `references_skipped`, whose own check is shallow and can be
evaluated before a same-pass referent is marked skipped; whatever misses that fast path
still aborts loudly here instead of emitting a dangling integer.
"""
function lookup_id(ledger::Ledger, uuid::AbstractString)
    key = String(uuid)
    if is_skipped(ledger, key)
        throw(
            DanglingReferenceError(
                "uuid $key was skipped ($(skip_reason(ledger, key))) and cannot be referenced",
            ),
        )
    end
    if !haskey(ledger.ids, key)
        throw(DanglingReferenceError("no id assigned for uuid $key"))
    end
    return ledger.ids[key]
end

function mark_skipped!(ledger::Ledger, uuid::AbstractString, reason::AbstractString)
    ledger.skipped[String(uuid)] = String(reason)
    return nothing
end

is_skipped(ledger::Ledger, uuid::AbstractString) = haskey(ledger.skipped, String(uuid))

"""
Keep `value`, a PSY5 value with no PSY6 field, for the component being translated, under
`key` (the field name, or `Type.field` for a field of a nested struct). Every caller also
records the field on the `ConversionReport`; this is what keeps the value itself. A `nothing`
value has nothing to keep, and outside `translate_component` there is no owner to keep it on.
"""
function keep_unmapped!(ledger::Ledger, key::AbstractString, value)
    if isnothing(ledger.owner) || isnothing(value)
        return nothing
    end
    get!(Dict{String, Any}, ledger.unmapped, ledger.owner)[String(key)] = value
    return nothing
end

unmapped_values(ledger::Ledger, uuid::AbstractString) =
    get(ledger.unmapped, String(uuid), nothing)
skip_reason(ledger::Ledger, uuid::AbstractString) = ledger.skipped[String(uuid)]

_is_uuid_payload(::AbstractString) = true
_is_uuid_payload(::Any) = false

is_reference(::Any) = false
function is_reference(value::AbstractDict)
    if length(value) != 1 || !haskey(value, "value")
        return false
    end
    return _is_uuid_payload(value["value"])
end

reference_uuid(value::AbstractDict) = String(value["value"])
