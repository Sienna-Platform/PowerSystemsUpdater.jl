struct DanglingReferenceError <: Exception
    msg::String
end

Base.showerror(io::IO, e::DanglingReferenceError) =
    print(io, "DanglingReferenceError: ", e.msg)

"""
A PSY5 time series key embedded in a field (`FuelCurve.fuel_cost`) of `owner_uuid`. Written
as `placeholder`, a negative integer, until `resolve_series_refs` replaces it with the id of
the association the key names.
"""
struct SeriesRef
    placeholder::Int
    owner_uuid::String
    key::Dict{String, Any}
end

"""
Maps PSY5 component UUIDs onto PSY6's document-wide integer ids, and records skipped
components so references to them are detected rather than emitted dangling.

  - `owner`: the component being translated (`translate_component`).
  - `unmapped`: per component UUID, the PSY5 values with no PSY6 field, written to its `ext`
    (`_carry_ext!`).
  - `series_refs`: time series references deferred until the catalog assigns association ids
    (`defer_series_ref!`).
  - `bus_voltage_setpoints`: by bus UUID, the setpoint a device gives the bus it regulates,
    written onto the buses at the end (`_apply_bus_voltage_setpoints`).
"""
mutable struct Ledger
    ids::Dict{String, Int}
    skipped::Dict{String, String}
    counter::Int
    owner::Union{Nothing, String}
    unmapped::Dict{String, Dict{String, Any}}
    series_refs::Vector{SeriesRef}
    bus_voltage_setpoints::Dict{String, Float64}
end

Ledger() = Ledger(
    Dict{String, Int}(),
    Dict{String, String}(),
    0,
    nothing,
    Dict{String, Dict{String, Any}}(),
    SeriesRef[],
    Dict{String, Float64}(),
)

"""Assign an id to `uuid`, or return the one already assigned."""
function assign_id!(ledger::Ledger, uuid::AbstractString)
    key = String(uuid)
    if haskey(ledger.ids, key)
        return ledger.ids[key]
    end
    ledger.counter += 1
    ledger.ids[key] = ledger.counter
    return ledger.counter
end

"""Reserve an id for a component translation synthesizes, such as a transformer circuit."""
function allocate_id!(ledger::Ledger)
    ledger.counter += 1
    return ledger.counter
end

has_id(ledger::Ledger, uuid::AbstractString) = haskey(ledger.ids, String(uuid))

"""
Resolve `uuid` to its id; every reference resolution goes through here. Throws for a skipped
or unknown `uuid`, backstopping `references_skipped`, whose check is shallow.
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
Keep `value`, a PSY5 value with no PSY6 field, on the component being translated under `key`
(the field name, or `Type.field` for a nested struct). Callers also record the field on the
report. A `nothing` value, or no owner outside `translate_component`, keeps nothing.
"""
function keep_unmapped!(ledger::Ledger, key::AbstractString, value)
    if isnothing(ledger.owner) || isnothing(value)
        return nothing
    end
    get!(Dict{String, Any}, ledger.unmapped, ledger.owner)[String(key)] = value
    return nothing
end

"""Defer an embedded time series `key`, returning the placeholder to write in its place."""
function defer_series_ref!(ledger::Ledger, key::AbstractDict)
    if isnothing(ledger.owner)
        throw(Psy5FormatError("a time series key outside any component cannot be resolved"))
    end
    placeholder = -(length(ledger.series_refs) + 1)
    push!(ledger.series_refs, SeriesRef(placeholder, ledger.owner, Dict{String, Any}(key)))
    return placeholder
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
