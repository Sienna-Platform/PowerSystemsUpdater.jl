const TIME_SERIES_FILENAME = "time_series.h5"

"""
Read PSY5's `time_series_associations` table.

The metadata is a whole SQLite database stored as a byte array inside the HDF5 file.
`IS.from_h5_file` would extract it and hand back a fully reconstructed
`TimeSeriesMetadataStore`, but building that reconstruction deserializes each row's
`scaling_factor_multiplier` into an actual `Function` object — which, for real corpus data,
requires the `PowerSystems` module to already be loaded (e.g. to resolve
`PowerSystems.get_max_active_power`). This package does not and must not depend on
PowerSystems, so 9 of the 73 corpus sidecars make that reconstruction throw. Since only the
raw association rows are needed here, the same byte extraction IS performs is replicated and
the resulting SQLite file is queried directly, skipping the reconstruction entirely.
"""
function read_associations(h5_path::AbstractString)
    return mktempdir() do scratch
        data = IS.HDF5.h5open(h5_path, "r") do file
            return file[IS.HDF5_TS_METADATA_ROOT_PATH][:]
        end
        filename, io = mktemp(scratch)
        write(io, data)
        close(io)
        db = SQLite.DB(filename)
        query = SQLite.DBInterface.execute(db, "SELECT * FROM time_series_associations")
        return [
            Dict{String, Any}(string(k) => v for (k, v) in pairs(row))
            for row in Tables.rowtable(query)
        ]
    end
end

_association_value(::Nothing) = nothing
_association_value(::Missing) = nothing
_association_value(value) = value

function _optional_string_field(row::AbstractDict, key::AbstractString)
    value = _association_value(get(row, key, nothing))
    if isnothing(value)
        return nothing
    end
    return string(value)
end

"""
PSY5's `scaling_factor_multiplier` column holds either `NULL` or `InfrastructureSystems`'s
serialized-`Function` marker (`{"__metadata__":{"module":...,"function":...}}`). PSY6's
schema wants the dot-encoded name instead (`PowerSystems.get_max_active_power`), so the
marker is decoded rather than passed through as raw JSON text.
"""
function _scaling_factor_multiplier(row::AbstractDict)
    value = _association_value(get(row, "scaling_factor_multiplier", nothing))
    if isnothing(value)
        return nothing
    end
    parsed = JSON.parse(String(value); dicttype = Dict{String, Any})
    if !haskey(parsed, "__metadata__")
        throw(Psy5FormatError("unrecognized scaling_factor_multiplier payload: $value"))
    end
    metadata = parsed["__metadata__"]
    return string(metadata["module"], ".", metadata["function"])
end

"""
PSY5's association columns match PSY6's `TimeSeriesAssociation` field-for-field except that
the owner is a UUID rather than an integer id.
"""
function to_time_series_association(row::AbstractDict, ledger::Ledger)
    owner_uuid = row["owner_uuid"]
    return PCOM.TimeSeriesAssociation(;
        id = _association_value(get(row, "id", nothing)),
        time_series_uuid = string(row["time_series_uuid"]),
        time_series_type = string(row["time_series_type"]),
        initial_timestamp = TimeZones.ZonedDateTime(
            TimeZones.DateTime(string(row["initial_timestamp"])),
            TimeZones.tz"UTC",
        ),
        resolution = string(row["resolution"]),
        horizon = _optional_string_field(row, "horizon"),
        interval = _optional_string_field(row, "interval"),
        window_count = _association_value(get(row, "window_count", nothing)),
        length = _association_value(get(row, "length", nothing)),
        name = string(row["name"]),
        owner_id = lookup_id(ledger, owner_uuid),
        owner_type = string(row["owner_type"]),
        owner_category = string(row["owner_category"]),
        features = Dict{String, PCOM.FeatureValue}[],
        scaling_factor_multiplier = _scaling_factor_multiplier(row),
        metadata_uuid = _optional_string_field(row, "metadata_uuid"),
        units = _optional_string_field(row, "units"),
    )
end

"""
Copy the HDF5 sidecar verbatim. IS3 and IS4 storage formats are identical, so no rewrite is
needed and none is attempted.
"""
function copy_time_series(case::Psy5Case, out_dir::AbstractString)
    destination = joinpath(out_dir, TIME_SERIES_FILENAME)
    cp(case.time_series_path, destination; force = true)
    return destination
end
