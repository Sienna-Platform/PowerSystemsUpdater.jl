const PSY5_FORMAT_VERSION = "5.0.0"

struct Psy5FormatError <: Exception
    msg::String
end

Base.showerror(io::IO, e::Psy5FormatError) = print(io, "Psy5FormatError: ", e.msg)

struct Psy5Case
    raw::Dict{String, Any}
    path::String
    time_series_path::Union{Nothing, String}
end

"""
Read a PSY5 `to_json` bundle. `path` is the extensionless system file; the HDF5 sidecar is
located by PSY5's own naming rule (`splitext(basename)` + `_time_series_storage.h5`).
"""
function read_psy5(path::AbstractString)
    if !isfile(path)
        throw(Psy5FormatError("no such file: $path"))
    end
    raw = JSON.parsefile(path; dicttype = Dict{String, Any})
    version = get(raw, "data_format_version", "<absent>")
    if version != PSY5_FORMAT_VERSION
        throw(
            Psy5FormatError(
                "expected data_format_version $PSY5_FORMAT_VERSION, got $version in $path",
            ),
        )
    end
    return Psy5Case(raw, String(path), _sidecar_path(path, raw))
end

function _sidecar_path(path::AbstractString, raw::AbstractDict)
    data = raw["data"]
    if !haskey(data, "time_series_storage_file")
        return nothing
    end
    return joinpath(dirname(abspath(path)), data["time_series_storage_file"])
end

has_time_series(case::Psy5Case) = !isnothing(case.time_series_path)

function system_base_power(case::Psy5Case)
    return Float64(case.raw["units_settings"]["base_value"])
end

components(case::Psy5Case) = case.raw["data"]["components"]

function supplemental_attributes(case::Psy5Case)
    manager = get(case.raw["data"], "supplemental_attribute_manager", nothing)
    if isnothing(manager)
        return Any[]
    end
    return get(manager, "attributes", Any[])
end

function supplemental_associations(case::Psy5Case)
    manager = get(case.raw["data"], "supplemental_attribute_manager", nothing)
    if isnothing(manager)
        return Any[]
    end
    return get(manager, "associations", Any[])
end

component_type(raw::AbstractDict) = raw["__metadata__"]["type"]

function component_parameters(raw::AbstractDict)
    metadata = raw["__metadata__"]
    if !haskey(metadata, "parameters")
        return String[]
    end
    return String.(metadata["parameters"])
end

"""
The UUID PSY5 uses to reference this component.
"""
component_uuid(raw::AbstractDict) = raw["internal"]["uuid"]["value"]::String
