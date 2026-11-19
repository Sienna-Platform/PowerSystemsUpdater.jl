const TIME_SERIES_FILENAME = "time_series.h5"

"""
The HDF5 dataset PSY5 embeds its metadata SQLite database in.

Named here rather than read from `IS.HDF5_TS_METADATA_ROOT_PATH` because that constant no
longer exists: IS moved its storage to `InfraStore` and dropped HDF5 entirely. The path
describes the legacy on-disk format this package reads, so it belongs to the reader.
"""
const PSY5_TS_METADATA_ROOT_PATH = "time_series_metadata"

"""
Read PSY5's `time_series_associations` table.

`IS.from_h5_file` cannot be used: it reconstructs a `TimeSeriesMetadataStore`, which
deserializes `scaling_factor_multiplier` into a live `Function` and so requires `PowerSystems`
to be loaded. This package must not depend on it. Only the raw rows are needed, so IS's byte
extraction is replicated and the SQLite file queried directly.
"""
function read_associations(h5_path::AbstractString)
    return mktempdir() do scratch
        data = HDF5.h5open(h5_path, "r") do file
            return file[PSY5_TS_METADATA_ROOT_PATH][:]
        end
        filename, io = mktemp(scratch)
        write(io, data)
        close(io)
        db = SQLite.DB(filename)
        query = SQLite.DBInterface.execute(db, "SELECT * FROM time_series_associations")
        rows = [
            Dict{String, Any}(string(k) => v for (k, v) in pairs(row))
            for row in Tables.rowtable(query)
        ]
        SQLite.DBInterface.close!(db)
        return rows
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
serialized-`Function` marker (`{"__metadata__":{"module":...,"function":...}}`). The marker is
decoded to the bare accessor name (`get_max_active_power`); the `PowerSystems.` module prefix
it carries is dropped because the name is read as a label here, never resolved to a function —
this package deliberately does not depend on `PowerSystems`.
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
    return string(parsed["__metadata__"]["function"])
end

"""
The physical quantity a normalized series scales back to, keyed by the PSY5 accessor that
named the base.

Values are `quantity_types` names from `SiennaSchemas`' `Core/units.json`, the vocabulary
PSY6's `quantity_kind` column draws on. With `unit_system` set to `COMPONENT_BASE` the values
are dimensionless, so this is the only remaining record of what they measure.

The reservoir accessors (`get_storage_capacity`, `get_storage_target`, `get_inflow`) are
deliberately absent: their quantity depends on the owning reservoir's `level_data_type`
(a level is an energy, a volume, or a head), which is not resolvable from an association row.
[`_quantity_kind`](@ref) reports those rather than guessing one.
"""
const MULTIPLIER_QUANTITY_KINDS = Dict(
    "get_max_active_power" => "ActivePower",
    "get_peak_active_power" => "ActivePower",
    "get_requirement" => "ActivePower",
    "get_max_reactive_power" => "ReactivePower",
)

"""
The `quantity_kind` a multiplier names, or `nothing` when this translator cannot determine
one. Shared by the document row and the InfraStore catalog row, which must agree.
"""
_multiplier_quantity_kind(::Nothing) = nothing
_multiplier_quantity_kind(multiplier::AbstractString) =
    get(MULTIPLIER_QUANTITY_KINDS, multiplier, nothing)

# An undeterminable quantity is recorded as an unmapped field rather than dropped silently
# or guessed at: a wrong quantity label is worse than an absent one, and the report is where
# this package puts everything it could not carry across.
_record_absent_quantity_kind(kind::AbstractString, ::AbstractDict, ::ConversionReport) =
    kind

function _record_absent_quantity_kind(
    ::Nothing,
    row::AbstractDict,
    report::ConversionReport,
)
    record_unmapped_field!(report, string(row["owner_type"]), "quantity_kind")
    return nothing
end

"""
`quantity_kind` for a row's multiplier. A row with no multiplier declares no quantity and
reports nothing; one whose accessor names no determinable quantity is reported.
"""
_quantity_kind(::Nothing, ::AbstractDict, ::ConversionReport) = nothing

_quantity_kind(multiplier::AbstractString, row::AbstractDict, report::ConversionReport) =
    _record_absent_quantity_kind(
        _multiplier_quantity_kind(multiplier),
        row,
        report,
    )

"""
Whether a row's owner survived translation, and so whether the row can be carried across at
all. Both the document's association rows and the InfraStore catalog's are filtered through
this, so the two always describe the same set of series.
"""
owner_translated(ledger::Ledger, row::AbstractDict) =
    has_id(ledger, row["owner_uuid"]) && !is_skipped(ledger, row["owner_uuid"])

"""
Feature names PSY6 reserves because they name a field of a time series or of the key that
addresses one (the `TimeSeriesFeatures.propertyNames` exclusion in SiennaSchemas). PSY5 had
no such rule, and tools that build PSY5 systems from other models write some of them (a
model year as `horizon`), so [`_features`](@ref) renames them.
"""
const RESERVED_FEATURE_NAMES = Set([
    "application_data", "array_shape", "association_id", "component_field", "count",
    "data",
    "data_hash", "dtype", "element_shape", "element_type", "ext", "features", "horizon",
    "id",
    "initial_timestamp", "interval", "interval_alignment", "length", "name",
    "owner_category",
    "owner_id", "owner_type", "per_unit_of", "percentiles", "quantity_kind",
    "resolution",
    "scenario_count", "time_reference", "time_series_type", "timestamps",
    "timestamps_uri",
    "unit_system", "units", "uri",
])

const RESERVED_FEATURE_SUFFIX = "_feature"

"""A PSY5 feature name as PSY6 stores it: a reserved name gets `_feature` appended."""
function _psy6_feature_name(name::AbstractString)
    if name in RESERVED_FEATURE_NAMES
        return name * RESERVED_FEATURE_SUFFIX
    end
    return String(name)
end

_psy6_features(features::AbstractDict) =
    Dict{String, Any}(_psy6_feature_name(k) => v for (k, v) in features)

function _features_error(row::AbstractDict, value, problem::AbstractString)
    return Psy5FormatError(
        "time series features $value on name=$(row["name"]) " *
        "owner_type=$(row["owner_type"]): $problem",
    )
end

"""
A row's PSY5 features as a dictionary. PSY5 stores them as a JSON list of one-pair objects
(`[{"year":2024}]`) with Bool, Int or String values, the encoding IS3's reader expects.
"""
function _psy5_features(row::AbstractDict)
    features = Dict{String, Any}()
    value = _association_value(get(row, "features", nothing))
    if isnothing(value)
        return features
    end
    for pair in JSON.parse(String(value))
        if length(pair) != 1
            throw(_features_error(row, value, "each entry must hold exactly one pair"))
        end
        name, feature = only(pair)
        if haskey(features, name)
            throw(_features_error(row, value, "duplicate feature \"$name\""))
        end
        features[String(name)] = feature
    end
    return features
end

"""A row's features as PSY6 stores them, reserved names renamed by [`_psy6_feature_name`](@ref)."""
function _features(row::AbstractDict)
    psy5 = _psy5_features(row)
    features = _psy6_features(psy5)
    if length(features) != length(psy5)
        throw(_features_error(row, psy5, "a renamed feature collides with another"))
    end
    return features
end

"""Warn about and report each feature [`_features`](@ref) renames on `row`."""
function _record_feature_renames!(row::AbstractDict, report::ConversionReport)
    owner_type = string(row["owner_type"])
    for name in keys(_psy5_features(row))
        if name in RESERVED_FEATURE_NAMES
            @warn "time series feature \"$name\" is reserved in PSY6; carried as " *
                  "\"$(_psy6_feature_name(name))\" (first seen on $owner_type " *
                  "\"$(row["name"])\")" maxlog = 1
            record_approximate_mapping!(report, owner_type, "features.$name")
        end
    end
    return nothing
end
