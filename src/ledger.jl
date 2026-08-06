struct DanglingReferenceError <: Exception
    msg::String
end

Base.showerror(io::IO, e::DanglingReferenceError) =
    print(io, "DanglingReferenceError: ", e.msg)

"""
Maps PSY5 component UUIDs onto the document-wide unique integer ids PSY6 requires, and
records components that were skipped so references to them can be detected rather than
emitted as dangling integers.
"""
mutable struct Ledger
    ids::Dict{String, Int}
    skipped::Dict{String, String}
    counter::Base.RefValue{Int}
end

Ledger() = Ledger(Dict{String, Int}(), Dict{String, String}(), Ref(0))

"""
Assign an id to `uuid`, or return the one already assigned. Idempotent.
"""
function assign_id!(ledger::Ledger, uuid::AbstractString)
    key = String(uuid)
    if haskey(ledger.ids, key)
        return ledger.ids[key]
    end
    ledger.counter[] += 1
    ledger.ids[key] = ledger.counter[]
    return ledger.counter[]
end

"""
Reserve an id for a component that translation synthesizes and that has no PSY5 UUID —
transformer circuits, for instance.
"""
function allocate_id!(ledger::Ledger)
    ledger.counter[] += 1
    return ledger.counter[]
end

has_id(ledger::Ledger, uuid::AbstractString) = haskey(ledger.ids, String(uuid))

function lookup_id(ledger::Ledger, uuid::AbstractString)
    key = String(uuid)
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
