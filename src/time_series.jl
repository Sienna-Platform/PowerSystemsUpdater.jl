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
The basis PSY6 records for values a PSY5 multiplier normalized.

PSY5 stored such a series as a fraction and named an accessor to scale it by at read time.
PSY6 removed `scaling_factor_multiplier` and rescales nothing, so what carries the meaning
across is the declaration that the values are per-unit on the owner's own base — which is
what `DEVICE_BASE` says. Mirrors `PowerTableDataParser`'s handling of the same removal.
"""
const DEVICE_BASE_UNIT_SYSTEM = "DEVICE_BASE"

"""
The physical quantity a normalized series scales back to, keyed by the PSY5 accessor that
named the base.

Values are `quantity_types` names from `SiennaSchemas`' `Core/units.json`, the vocabulary
PSY6's `quantity_kind` column draws on. With `unit_system` set to `DEVICE_BASE` the values
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

_unit_system(::Nothing) = nothing
_unit_system(::AbstractString) = DEVICE_BASE_UNIT_SYSTEM

"""
Whether a row's owner survived translation, and so whether the row can be carried across at
all. Both the document's association rows and the InfraStore catalog's are filtered through
this, so the two always describe the same set of series.
"""
owner_translated(ledger::Ledger, row::AbstractDict) =
    has_id(ledger, row["owner_uuid"]) && !is_skipped(ledger, row["owner_uuid"])

"""
PSY5's `features` column is a JSON-encoded list. This translator has no destination for a
populated one, so a non-empty value fails loudly rather than being dropped.
"""
function _features(row::AbstractDict)
    value = _association_value(get(row, "features", nothing))
    if isnothing(value)
        return Dict{String, PCOM.FeatureValue}[]
    end
    parsed = JSON.parse(String(value))
    if !isempty(parsed)
        throw(
            Psy5FormatError(
                "non-empty time series features are not supported: " *
                "name=$(row["name"]) owner_type=$(row["owner_type"]) features=$value",
            ),
        )
    end
    return Dict{String, PCOM.FeatureValue}[]
end

"""
Translate one PSY5 association row into PSY6's `TimeSeriesAssociation`.

Three PSY5 columns have no PSY6 column to land in. `time_series_uuid` and `metadata_uuid` are
gone with UUID identity itself — the sidecar is addressed by `time_series_storage_file` and
the row's own `id`. `scaling_factor_multiplier` is gone because PSY6 rescales nothing on
retrieval; its meaning is re-expressed as `unit_system` plus `quantity_kind`.

`element_type` and `application_data` are left unset. Both describe the stored array, and
PSY6 reads an array's description from the sidecar catalog rather than from the document —
[`convert_time_series`](@ref) writes `element_type` there — so filling them in here would add
a second copy with no reader.

The caller must exclude rows whose owner was skipped (`is_skipped(ledger, owner_uuid)`) —
this function resolves `owner_id` unconditionally via `lookup_id` and raises
`DanglingReferenceError` if the owner has no assigned id.
"""
function to_time_series_association(
    row::AbstractDict,
    ledger::Ledger,
    report::ConversionReport,
)
    owner_uuid = row["owner_uuid"]
    multiplier = _scaling_factor_multiplier(row)
    return PCOM.TimeSeriesAssociation(;
        id = _association_value(get(row, "id", nothing)),
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
        features = _features(row),
        units = _optional_string_field(row, "units"),
        # PENDING RENAME: the generated `TimeSeriesAssociation` field is `quantity_type` at
        # the `[sources]` rev; `quantity_kind` is the decided spelling and its regeneration
        # is in flight. This line needs that rev, not a change here.
        quantity_kind = _quantity_kind(multiplier, row, report),
        unit_system = _unit_system(multiplier),
    )
end
