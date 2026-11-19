# Version-neutral half of the system snapshot, included by both snapshot scripts. It must not
# reference PowerSystems: PSY5 and PSY6 share a package UUID and cannot be loaded in one
# process, which is why the comparison goes through a JSON snapshot.
#
# Each includer defines `const IS` (its InfrastructureSystems) before including this file, and
# these functions for its PowerSystems version:
#   - `list_series(owner)`: a handle per time series on `owner` (IS3: a key, IS4: a metadata row).
#   - `series_type(handle)`: the *stored* type; IS4 reads a derived forecast back as a plain
#     `Deterministic`, so it must come from the catalog.
#   - `series_name(handle)`, `series_metadata(handle)` (a `Dict` of `initial_timestamp`,
#     `resolution`, `horizon`, `interval`, `count`, `length`, `features`; `nothing` where one
#     does not apply), `read_series(owner, handle)`, `natural_scale(owner, handle)`.
#   - `read_field(x, field::Symbol)`: the value through its getter, in system base units.
#   - `snapshot_value(x::PowerSystems.Component)`: a reference record (`component_ref`).
#   - `all_components(sys)` (including masked), `services_of(component)`,
#     `supplemental_attributes(sys)`, `associated_components(sys, attribute)`,
#     `system_header(sys)`.

import Dates
import HDF5
import JSON

# Bookkeeping fields, never compared.
const SKIPPED_FIELDS =
    (:internal, :time_series_container, :supplemental_attributes_container)

"""
The type's name without module qualifiers.
"""
type_label(::Type{T}) where {T} =
    replace(string(T), r"(?:[A-Za-z_][A-Za-z0-9_]*\.)+(?=[A-Za-z_])" => "")

"""
`PrimeMovers.ST` and `PrimeMoversModule.ST` both become `"ST"`.
"""
enum_label(x::Enum) = last(split(string(x), '.'))

snapshot_value(::Nothing) = nothing
snapshot_value(x::Bool) = x
snapshot_value(x::Integer) = Int(x)
# JSON cannot hold NaN/Inf; strings still compare equal to themselves.
snapshot_value(x::AbstractFloat) = isfinite(x) ? Float64(x) : string(x)
snapshot_value(x::Complex) =
    Dict{String, Any}("re" => snapshot_value(real(x)), "im" => snapshot_value(imag(x)))
snapshot_value(x::AbstractString) = String(x)
snapshot_value(x::Symbol) = String(x)
snapshot_value(x::Enum) = enum_label(x)
snapshot_value(x::Type) = type_label(x)
snapshot_value(x::Base.UUID) = string(x)
snapshot_value(x::Dates.TimeType) = string(x)
# `Hour(1)` and `Millisecond(3_600_000)` describe the same resolution.
snapshot_value(x::Dates.Period) = string(Dates.canonicalize(Dates.CompoundPeriod(x)))
snapshot_value(x::Dates.CompoundPeriod) = string(Dates.canonicalize(x))
snapshot_value(x::NamedTuple) =
    Dict{String, Any}(string(k) => snapshot_value(v) for (k, v) in pairs(x))
snapshot_value(x::Union{Tuple, AbstractArray}) = Any[snapshot_value(v) for v in x]
snapshot_value(x::AbstractDict) =
    Dict{String, Any}(string(k) => snapshot_value(v) for (k, v) in x)

"""
Any other struct (cost curves, transformer circuits, ...): its fields, tagged with its type.
"""
function snapshot_value(x)
    record = struct_record(x)
    record["__type__"] = type_label(typeof(x))
    return record
end

function struct_record(x)
    record = Dict{String, Any}()
    for field in fieldnames(typeof(x))
        if field in SKIPPED_FIELDS
            continue
        end
        record[string(field)] = attempt(() -> snapshot_value(read_field(x, field)))
    end
    return record
end

component_ref(type_name::AbstractString, name::AbstractString) =
    Dict{String, Any}("__ref__" => type_name, "name" => name)

"""
Run `f`, returning an `__error__` record instead of throwing, so one unreadable value does not
lose the rest of the snapshot.
"""
function attempt(f)
    try
        return f()
    catch e
        return Dict{String, Any}("__error__" => first(split(sprint(showerror, e), '\n')))
    end
end

"""
The HDF5 file holding every time series' values, one dataset per series, so the comparison
can check them element by element without putting arrays in the JSON.
"""
mutable struct ValuesWriter
    file::HDF5.File
    count::Int
end

ValuesWriter(file::HDF5.File) = ValuesWriter(file, 0)

function next_dataset!(writer::ValuesWriter)
    writer.count += 1
    return "series/$(writer.count)"
end

write_dataset!(writer::ValuesWriter, values::AbstractArray{<:Real}) =
    _write_dataset!(writer, Float64.(values))

# Non-scalar elements (e.g. PiecewiseStepData) are stored as snapshot JSON strings.
write_dataset!(writer::ValuesWriter, values::AbstractArray) =
    _write_dataset!(writer, map(v -> JSON.json(snapshot_value(v)), values))

function _write_dataset!(writer::ValuesWriter, values::AbstractArray)
    path = next_dataset!(writer)
    writer.file[path] = values
    return path
end

"""
Where a series' values went, and their shape. A forecast is a horizon × window matrix, with
each window's start so a mismatch can be reported as a timestamp.
"""
function values_record(writer::ValuesWriter, ts)
    values, window_starts = time_series_values(ts)
    return Dict{String, Any}(
        "dataset" => write_dataset!(writer, values),
        "shape" => collect(size(values)),
        "window_starts" => snapshot_value(window_starts),
    )
end

"""
Metadata for one time series from its catalog entry, with its values written raw to `writer`.
`natural_scale` takes the stored values to natural units, so the comparison checks the
physical series even where the updater rescales what it stores.
"""
function time_series_record(writer::ValuesWriter, owner, handle)
    T = series_type(handle)
    record = Dict{String, Any}(
        # Bare name: PSY6 adds element type parameters (`Deterministic{Float64, 1}`).
        "type" => string(nameof(T)),
        "name" => series_name(handle),
    )
    for (key, value) in series_metadata(handle)
        record[key] = attempt(() -> snapshot_value(value))
    end
    record["values"] = attempt(() -> values_record(writer, T, owner, handle))
    record["natural_scale"] = attempt(() -> natural_scale(owner, handle))
    return record
end

"""
A `DeterministicSingleTimeSeries` stores no data: it views the `SingleTimeSeries` of the same
name and resolution, which is compared on its own.
"""
function values_record(
    ::ValuesWriter,
    ::Type{<:IS.DeterministicSingleTimeSeries},
    _,
    handle,
)
    return Dict{String, Any}(
        "derived_from" => Dict{String, Any}(
            "type" => "SingleTimeSeries",
            "name" => series_name(handle),
            "resolution" => snapshot_value(series_metadata(handle)["resolution"]),
        ),
    )
end

values_record(writer::ValuesWriter, ::Type, owner, handle) =
    values_record(writer, read_series(owner, handle))

"""
The series' values and each forecast window's start (`nothing` for a static series).
"""
time_series_values(ts::IS.StaticTimeSeries) =
    (IS.TimeSeries.values(IS.get_data(ts)), nothing)

function time_series_values(ts::IS.Forecast)
    windows = collect(IS.iterate_windows(ts))
    if isempty(windows)
        return (Matrix{Float64}(undef, 0, 0), Dates.DateTime[])
    end
    values = reduce(hcat, [IS.TimeSeries.values(w) for w in windows])
    return (values, [first(IS.TimeSeries.timestamp(w)) for w in windows])
end

"""
Every time series on `owner`, sorted.
"""
function time_series_records(writer::ValuesWriter, owner)
    if !IS.supports_time_series(owner)
        return Any[]
    end
    records = [time_series_record(writer, owner, h) for h in list_series(owner)]
    sort!(records; by = r -> (r["type"], r["name"], string(get(r, "resolution", ""))))
    return records
end

ref_sort_key(r) = (r["__ref__"], r["name"])

function component_record(component)
    record = struct_record(component)
    # A field in PSY5 and an association in PSY6; read the same way on both sides.
    delete!(record, "services")
    record["services"] = attempt(
        () -> sort!(
            Any[snapshot_value(s) for s in services_of(component)];
            by = ref_sort_key,
        ),
    )
    return record
end

function supplemental_attribute_record(writer::ValuesWriter, sys, attribute)
    record = struct_record(attribute)
    record["__type__"] = type_label(typeof(attribute))
    record["components"] = attempt(
        () -> sort!(
            Any[snapshot_value(c) for c in associated_components(sys, attribute)];
            by = ref_sort_key,
        ),
    )
    record["time_series"] = attempt(() -> time_series_records(writer, attribute))
    return record
end

"""
Attributes have no name, so they are listed, ordered by content.
"""
function supplemental_attribute_records(writer::ValuesWriter, sys)
    records = Any[
        supplemental_attribute_record(writer, sys, a) for a in supplemental_attributes(sys)
    ]
    sort!(records; by = JSON.json)
    return records
end

"""
The snapshot of `sys`: components keyed by type then name, their time series, and the
supplemental attributes. Time series values go to `writer`.
"""
function snapshot_system(sys, writer::ValuesWriter)
    components = Dict{String, Dict{String, Any}}()
    time_series = Dict{String, Dict{String, Any}}()
    for component in all_components(sys)
        label = type_label(typeof(component))
        name = read_field(component, :name)
        get!(Dict{String, Any}, components, label)[name] = component_record(component)
        ts = attempt(() -> time_series_records(writer, component))
        if has_entries(ts)
            get!(Dict{String, Any}, time_series, label)[name] = ts
        end
    end
    return Dict{String, Any}(
        "system" => system_header(sys),
        "components" => components,
        "time_series" => time_series,
        "supplemental_attributes" =>
            attempt(() -> supplemental_attribute_records(writer, sys)),
    )
end

"""
Write the JSON snapshot of `sys` and its time series values into `dir`.
"""
function write_snapshot(sys, dir::AbstractString, snapshot_file, values_file)
    snapshot = HDF5.h5open(joinpath(dir, values_file), "w") do file
        snapshot_system(sys, ValuesWriter(file))
    end
    open(joinpath(dir, snapshot_file), "w") do io
        JSON.json(io, snapshot; pretty = true)
    end
end

# An `attempt` error record counts as an entry, so a failure is never dropped.
has_entries(x::AbstractVector) = !isempty(x)
has_entries(::AbstractDict) = true
