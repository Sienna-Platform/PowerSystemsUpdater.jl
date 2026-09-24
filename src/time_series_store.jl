# Rewriting a PSY5 time series sidecar as an InfraStore store.
#
# The two formats share nothing but the `.h5` extension. PSY5 keys one HDF5 group per time
# series UUID under `/time_series` and embeds its association table as a SQLite blob in a
# second dataset. InfraStore content-addresses every array by its SHA-256 and keeps the
# associations in a sibling `<name>.h5.sqlite` catalog, which is what PSY6's importer adopts
# as the System's time series store. A byte copy therefore produces a bundle whose arrays no
# reader can resolve, so the arrays are decoded and re-added through `InfraStore.jl` rather
# than moved. Nothing here writes HDF5 layout or SQL: the store owns both halves.

"""
The HDF5 group PSY5 keys its time series arrays under, one subgroup per time series UUID,
each holding a `data` dataset plus `module`/`type`/`data_type` attributes.

Named here rather than imported because IS dropped HDF5 storage when it moved to InfraStore.
The constant describes the legacy format this package reads, so it belongs to the reader.
"""
const PSY5_TS_ROOT_PATH = "time_series"

# ── Durations ───────────────────────────────────────────────────────────────────

"""
PSY5's duration encoding, one pattern per `Dates.Period` its writer emitted.

Ordered, and the first match wins, because the patterns overlap: `P0DT3600.000S` is a
`Millisecond` while `P0DT3600S` is a `Second`, and `P1M` is a month while `P0DT1M` is a
minute. This is the same ordered table the writer's own reader used.
"""
const PSY5_DURATION_PATTERNS = (
    (r"^P0DT(\d+\.\d+)S$", Dates.Millisecond),
    (r"^P0DT(\d+)S$", Dates.Second),
    (r"^P0DT(\d+)M$", Dates.Minute),
    (r"^P0DT(\d+)H$", Dates.Hour),
    (r"^P(\d+)D$", Dates.Day),
    (r"^P(\d+)W$", Dates.Week),
    (r"^P(\d+)M$", Dates.Month),
    (r"^P(\d+)Y$", Dates.Year),
)

# A fractional-second duration is a whole number of milliseconds; PSY5 wrote every
# sub-second resolution that way. Anything finer has no `Period` to land in.
function _psy5_duration_value(::Type{Dates.Millisecond}, text::AbstractString)
    value = parse(Float64, text) * 1000
    if !iszero(value % 1)
        throw(Psy5FormatError("PSY5 duration is finer than a millisecond: $text"))
    end
    return Int(value)
end

_psy5_duration_value(::Type{<:Dates.Period}, text::AbstractString) = parse(Int, text)

"""
Decode one PSY5 duration string into the `Dates.Period` InfraStore's writers take.
"""
function _psy5_duration(text::AbstractString)
    for (pattern, period) in PSY5_DURATION_PATTERNS
        matched = match(pattern, text)
        if !isnothing(matched)
            return period(_psy5_duration_value(period, matched.captures[1]))
        end
    end
    throw(Psy5FormatError("unrecognized PSY5 duration: $text"))
end

"""
The duration in a required association column, which is missing on rows whose type has no
use for it (a `SingleTimeSeries` carries no horizon). A row that needs one and has none is
malformed, not defaulted.
"""
function _required_duration(row::AbstractDict, key::AbstractString)
    text = _optional_string_field(row, key)
    if isnothing(text)
        throw(
            Psy5FormatError(
                "association id=$(row["id"]) of type $(row["time_series_type"]) has no " *
                "$key, which its type requires",
            ),
        )
    end
    return _psy5_duration(text)
end

# ── Element layouts ─────────────────────────────────────────────────────────────

"""
How PSY5 laid out one timestep's value, keyed by the `data_type` attribute it wrote beside
the array.

Only the layouts the PSY5 corpus actually contains are mapped. An unmapped one errors: the
two stores agree on plain scalars and on nothing else, so passing unknown bytes through
would have InfraStore decode them as a different value with no complaint from either side.
"""
abstract type Psy5ElementLayout end

"""One scalar per timestep. The only layout the two formats already agree on."""
struct ScalarLayout <: Psy5ElementLayout end

"""
A `PiecewiseStepData` per timestep.

PSY5 stored each as an `(n, 2)` matrix — `hcat(x_coords, [NaN; y_coords])` — NaN-padded along
its first axis to a common width and stacked. InfraStore stores the same value as one
self-describing matrix row, so the padding has to be read off and the row rebuilt.
"""
struct PiecewiseStepLayout <: Psy5ElementLayout end

const PSY5_ELEMENT_LAYOUTS = Dict{String, Psy5ElementLayout}(
    "CONSTANT" => ScalarLayout(),
    "PiecewiseStepData" => PiecewiseStepLayout(),
)

function _element_layout(label::AbstractString, row::AbstractDict)
    if !haskey(PSY5_ELEMENT_LAYOUTS, label)
        throw(
            Psy5FormatError(
                "no InfraStore encoding for PSY5 element layout \"$label\" " *
                "(name=$(row["name"]) owner_type=$(row["owner_type"]) " *
                "time_series_type=$(row["time_series_type"]))",
            ),
        )
    end
    return PSY5_ELEMENT_LAYOUTS[label]
end

# The number of x-coordinates in one PSY5 piecewise-step element. Counted from the
# x-column rather than taken from the padded width: PSY5 padded each element to the
# *element count* of the widest one, which for an (n, 2) matrix is 2n, so the stored
# width is twice the widest real coordinate count.
_piecewise_step_length(x_coords::AbstractVector{<:Real}) = count(!isnan, x_coords)

# Write one PSY5 piecewise-step element into InfraStore's row form: the coordinate count,
# then the n x-coordinates, then the n-1 y-coordinates. PSY5's y-column carries a leading
# NaN so its two columns line up, and that placeholder is dropped here.
function _write_piecewise_step_row!(
    out::AbstractMatrix{Float64},
    index::Integer,
    x_coords::AbstractVector{<:Real},
    y_coords::AbstractVector{<:Real},
)
    n = _piecewise_step_length(x_coords)
    out[index, 1] = n
    for j in 1:n
        out[index, 1 + j] = x_coords[j]
    end
    for j in 2:n
        out[index, n + j] = y_coords[j]
    end
    return nothing
end

"""
Values for a static series: the array as stored plus the `element_type` tag InfraStore keys
reconstruction on, or `nothing` for plain scalars of the array's own element type.
"""
_static_values(::ScalarLayout, data::AbstractVector{<:Real}) = (data, nothing)

function _static_values(::PiecewiseStepLayout, data::AbstractArray{<:Real, 3})
    steps, _, columns = size(data)
    if columns != 2
        throw(
            Psy5FormatError(
                "a PSY5 piecewise-step array must have 2 coordinate columns, got $columns",
            ),
        )
    end
    lengths = [_piecewise_step_length(view(data, i, :, 1)) for i in 1:steps]
    out = zeros(Float64, steps, 2 * maximum(lengths))
    for i in 1:steps
        _write_piecewise_step_row!(out, i, view(data, i, :, 1), view(data, i, :, 2))
    end
    return (out, "piecewise_step")
end

_static_values(layout::Psy5ElementLayout, data::AbstractArray) = throw(
    Psy5FormatError(
        "a static PSY5 array of layout $(nameof(typeof(layout))) cannot have " *
        "$(ndims(data)) dimensions",
    ),
)

"""
Values for a dense `Deterministic`: `(horizon_count, window_count)` for scalars, and
`(horizon_count, window_count, k)` once a row-encoded element gains its own axis — the same
shapes `InfraStore.Deterministic` takes.
"""
_window_values(::ScalarLayout, data::AbstractMatrix{<:Real}) = (data, nothing)

function _window_values(::PiecewiseStepLayout, data::AbstractArray{<:Real, 4})
    horizon, windows, _, columns = size(data)
    if columns != 2
        throw(
            Psy5FormatError(
                "a PSY5 piecewise-step array must have 2 coordinate columns, got $columns",
            ),
        )
    end
    lengths = [
        _piecewise_step_length(view(data, h, w, :, 1)) for h in 1:horizon,
        w in 1:windows
    ]
    width = 2 * maximum(lengths)
    out = zeros(Float64, horizon, windows, width)
    # One (horizon, width) slice per window, filled row-wise exactly as a static array is.
    slice = zeros(Float64, horizon, width)
    for w in 1:windows
        fill!(slice, 0.0)
        for h in 1:horizon
            _write_piecewise_step_row!(
                slice, h, view(data, h, w, :, 1), view(data, h, w, :, 2),
            )
        end
        out[:, w, :] = slice
    end
    return (out, "piecewise_step")
end

_window_values(layout::Psy5ElementLayout, data::AbstractArray) = throw(
    Psy5FormatError(
        "a PSY5 forecast array of layout $(nameof(typeof(layout))) cannot have " *
        "$(ndims(data)) dimensions",
    ),
)

# ── Reading one legacy array ────────────────────────────────────────────────────

"""
The stored array for an association, together with the layout of one of its timesteps.

A row naming an array the sidecar does not hold aborts the conversion: PSY6 resolves time
series through the catalog this pass writes, so an association with no array behind it would
read back as a series whose values silently went missing.
"""
function _legacy_array(file::HDF5.File, row::AbstractDict)
    uuid = string(row["time_series_uuid"])
    if !haskey(file, PSY5_TS_ROOT_PATH) || !haskey(file[PSY5_TS_ROOT_PATH], uuid)
        throw(
            Psy5FormatError(
                "the sidecar holds no array $uuid for association id=$(row["id"]) " *
                "(name=$(row["name"]) owner_type=$(row["owner_type"]))",
            ),
        )
    end
    group = file[PSY5_TS_ROOT_PATH][uuid]
    label = HDF5.read(HDF5.attributes(group)["data_type"])
    return HDF5.read(group["data"]), _element_layout(label, row)
end

_psy5_initial_timestamp(row::AbstractDict) =
    Dates.DateTime(string(row["initial_timestamp"]))

const PSY5_OWNER_CATEGORIES = Dict{String, InfraStore.OwnerCategory}(
    "Component" => InfraStore.Component,
    "SupplementalAttribute" => InfraStore.SupplementalAttribute,
)

function _owner_category(row::AbstractDict)
    name = string(row["owner_category"])
    if !haskey(PSY5_OWNER_CATEGORIES, name)
        throw(Psy5FormatError("unrecognized PSY5 owner_category: $name"))
    end
    return PSY5_OWNER_CATEGORIES[name]
end

"""
The basis InfraStore records for values a PSY5 multiplier normalized — the store's own
spelling of the `COMPONENT_BASE` the document's association row declares: a multiplier means
the values are per-unit on the owner's own base.
"""
_store_unit_system(::Nothing) = nothing
_store_unit_system(::AbstractString) = InfraStore.ComponentBase

"""
The store's feature dictionary for a row, which is always empty.

[`_features`](@ref) is what makes that true: it refuses a populated features list rather than
dropping it. Called here as well as on the document side so a conversion driven straight
through [`convert_time_series`](@ref) keeps the same guarantee — features are part of a
series' identity in InfraStore, so a dropped one would silently rename the series.
"""
_store_features(row::AbstractDict) = _features(row)

# ── Staging one association ─────────────────────────────────────────────────────

"""
Which of InfraStore's time series a PSY5 `time_series_type` becomes.

`DeterministicSingleTimeSeries` is a stored array in PSY5 and a *derivation* in InfraStore:
it shares its `SingleTimeSeries`' array and is re-described by
`InfraStore.transform_single_time_series!`. So it stages nothing and is handled in
[`_derive_forecasts!`](@ref) after every array is in the store.
"""
abstract type Psy5TimeSeriesKind end
struct SingleKind <: Psy5TimeSeriesKind end
struct DeterministicKind <: Psy5TimeSeriesKind end
struct DerivedDeterministicKind <: Psy5TimeSeriesKind end

const PSY5_TIME_SERIES_KINDS = Dict{String, Psy5TimeSeriesKind}(
    "SingleTimeSeries" => SingleKind(),
    "Deterministic" => DeterministicKind(),
    "DeterministicSingleTimeSeries" => DerivedDeterministicKind(),
)

"""
`Probabilistic` and `Scenarios` are deliberately unmapped: their percentiles and scenario
count live on the PSY5 metadata object, not in the association table this package reads, so
neither can be reconstructed from a row and neither appears in the PSY5 corpus. Erroring
names what is missing instead of writing a forecast with invented parameters.

`NonSequentialTimeSeries` is absent for a different reason, and its absence is correct rather
than pending: it exists only in the psy6 line, so no PSY5 system can contain one and there is
nothing to convert into one. Do not add a kind for it — a row naming it would mean the input
is not a PSY5 system, which this error should report.
"""
function _time_series_kind(row::AbstractDict)
    name = string(row["time_series_type"])
    if !haskey(PSY5_TIME_SERIES_KINDS, name)
        throw(
            Psy5FormatError(
                "no InfraStore conversion for PSY5 time series type \"$name\" " *
                "(name=$(row["name"]) owner_type=$(row["owner_type"]))",
            ),
        )
    end
    return PSY5_TIME_SERIES_KINDS[name]
end

"""
Stage one association's array onto `batch`.

`units`, `quantity_kind` and `unit_system` are the same three declarations the document's
`TimeSeriesAssociation` carries, written into the catalog because that is the copy PSY6's
importer reads: it adopts the sidecar's catalog as the System's store rather than replaying
the document's rows. InfraStore has always spelled it `quantity_kind`, so unlike the document
side this needs no rename.
"""
function _stage_time_series!(
    ::SingleKind,
    batch::InfraStore.AddBatch,
    file::HDF5.File,
    row::AbstractDict,
    owner_id::Int,
    report::ConversionReport,
)
    data, layout = _legacy_array(file, row)
    array, element_type = _static_values(layout, data)
    multiplier = _scaling_factor_multiplier(row)
    series = InfraStore.SingleTimeSeries(
        _psy5_initial_timestamp(row),
        _required_duration(row, "resolution"),
        array,
        string(row["name"]);
        element_type = element_type,
        units = _optional_string_field(row, "units"),
        quantity_kind = _quantity_kind(multiplier, row, report),
        unit_system = _store_unit_system(multiplier),
    )
    InfraStore.add_time_series!(
        batch,
        owner_id,
        string(row["owner_type"]),
        _owner_category(row),
        series;
        features = _store_features(row),
    )
    return nothing
end

function _stage_time_series!(
    ::DeterministicKind,
    batch::InfraStore.AddBatch,
    file::HDF5.File,
    row::AbstractDict,
    owner_id::Int,
    report::ConversionReport,
)
    data, layout = _legacy_array(file, row)
    array, element_type = _window_values(layout, data)
    windows = _window_count(row, size(array, 2))
    multiplier = _scaling_factor_multiplier(row)
    series = InfraStore.Deterministic(
        _psy5_initial_timestamp(row),
        _required_duration(row, "resolution"),
        _required_duration(row, "horizon"),
        _required_duration(row, "interval"),
        windows,
        array,
        string(row["name"]);
        element_type = element_type,
        units = _optional_string_field(row, "units"),
        quantity_kind = _quantity_kind(multiplier, row, report),
        unit_system = _store_unit_system(multiplier),
    )
    InfraStore.add_time_series!(
        batch,
        owner_id,
        string(row["owner_type"]),
        _owner_category(row),
        series;
        features = _store_features(row),
    )
    return nothing
end

# Derived forecasts store no array of their own; `_derive_forecasts!` re-describes the
# `SingleTimeSeries` they were derived from once every array is in the store.
function _stage_time_series!(
    ::DerivedDeterministicKind,
    ::InfraStore.AddBatch,
    ::HDF5.File,
    ::AbstractDict,
    ::Int,
    ::ConversionReport,
)
    return nothing
end

"""
The window count a `Deterministic` row declares, checked against the array behind it.

A disagreement means the row and the array describe different forecasts, and the store would
take the count on faith — so it aborts rather than writing a forecast whose windows do not
line up with its metadata.
"""
function _window_count(row::AbstractDict, from_array::Integer)
    declared = _association_value(get(row, "window_count", nothing))
    if isnothing(declared)
        throw(
            Psy5FormatError(
                "Deterministic association id=$(row["id"]) declares no window_count",
            ),
        )
    end
    if Int(declared) != Int(from_array)
        throw(
            Psy5FormatError(
                "Deterministic association id=$(row["id"]) declares " *
                "window_count=$declared but its array holds $from_array windows",
            ),
        )
    end
    return Int(declared)
end

# ── Derived forecasts ───────────────────────────────────────────────────────────

"""
Re-derive the `DeterministicSingleTimeSeries` rows as InfraStore derivations.

`InfraStore.transform_single_time_series!` works on every `SingleTimeSeries` at a resolution
at once, so it can only reproduce a PSY5 sidecar whose derived rows cover all of them. Both
preconditions are checked before anything is written — one `(horizon, interval)` per
resolution, and one derived row per static row — and a sidecar that breaks either aborts
rather than silently gaining or losing forecasts.

`normalize_single_window` and `require_uniform_forecast_grid` are set the way IS sets them,
because IS is what reads the result.
"""
function _derive_forecasts!(store::InfraStore.Store, rows::AbstractVector{<:AbstractDict})
    derived = _rows_of_kind(rows, DerivedDeterministicKind())
    isempty(derived) && return nothing
    static_owners = _association_identities(_rows_of_kind(rows, SingleKind()))
    for (resolution, group) in _group_by_resolution(derived)
        windows = unique((row["horizon"], row["interval"]) for row in group)
        if length(windows) != 1
            throw(
                Psy5FormatError(
                    "resolution $resolution carries derived forecasts over " *
                    "$(length(windows)) distinct (horizon, interval) pairs; InfraStore " *
                    "derives one window shape per resolution",
                ),
            )
        end
        sources = get(static_owners, resolution, Set{Tuple{String, String}}())
        covered = _association_identities(group)[resolution]
        if covered != sources
            throw(
                Psy5FormatError(
                    "resolution $resolution has $(length(covered)) derived forecasts over " *
                    "$(length(sources)) SingleTimeSeries; InfraStore derives from every " *
                    "series at a resolution or none, so a partial set cannot be " *
                    "reproduced (missing: $(collect(setdiff(sources, covered))))",
                ),
            )
        end
        outcome = InfraStore.transform_single_time_series!(
            store,
            _required_duration(first(group), "horizon"),
            _required_duration(first(group), "interval");
            resolution = _psy5_duration(resolution),
            normalize_single_window = true,
            require_uniform_forecast_grid = true,
        )
        if outcome.transformed != length(group)
            throw(
                Psy5FormatError(
                    "deriving forecasts at resolution $resolution wrote " *
                    "$(outcome.transformed) of the $(length(group)) the sidecar declares",
                ),
            )
        end
    end
    return nothing
end

_rows_of_kind(rows::AbstractVector{<:AbstractDict}, kind::Psy5TimeSeriesKind) =
    [row for row in rows if _time_series_kind(row) === kind]

function _group_by_resolution(rows::AbstractVector{R}) where {R <: AbstractDict}
    grouped = Dict{String, Vector{R}}()
    for row in rows
        push!(get!(grouped, string(row["resolution"]), R[]), row)
    end
    return grouped
end

# Association identity within a resolution: the (owner, name) pair, which is what InfraStore
# addresses a series by. Features are not part of it because `_features` has already refused
# any row that carries them.
function _association_identities(rows::AbstractVector{<:AbstractDict})
    identities = Dict{String, Set{Tuple{String, String}}}()
    for row in rows
        key = (String(row["owner_uuid"]), String(row["name"]))
        push!(
            get!(identities, string(row["resolution"]), Set{Tuple{String, String}}()),
            key,
        )
    end
    return identities
end

# ── Entry point ─────────────────────────────────────────────────────────────────

"""
Rewrite `case`'s PSY5 sidecar as the InfraStore pair PSY6 reads: `out_dir/time_series.h5`
holding the content-addressed arrays and `out_dir/time_series.h5.sqlite` holding the
catalog. Returns the `.h5` path (what the document names) together with the
`InfrastructureTimeSeriesOpenAPIModels.TimeSeriesAssociation` rows read back from the freshly
written catalog.

The two files are one artifact — the arrays are addressed by content hash and the catalog is
the only thing that says which association each hash belongs to — so they must travel
together.

The returned rows, not a document-side re-derivation of the PSY5 rows, are what the caller
must add to the document: they carry the `uri`/`data_hash`/`element_type`/`element_shape`
the store itself computed, so they are guaranteed to match what PSY6's importer will find in
the catalog. Rows whose owner was skipped are left out; their loss is recorded by
`_record_time_series_skips!`, which walks the same PSY5 rows to build the document.
"""
function convert_time_series(
    case::Psy5Case,
    ledger::Ledger,
    out_dir::AbstractString,
    report::ConversionReport,
)
    destination = joinpath(out_dir, TIME_SERIES_FILENAME)
    rows = [
        row for row in read_associations(case.time_series_path) if
        owner_translated(ledger, row)
    ]
    raw_store = InfraStore.Store(; path = destination, in_memory = false, overwrite = true)
    associations = POM.TimeSeriesAssociation[]
    try
        batch = InfraStore.AddBatch()
        HDF5.h5open(case.time_series_path, "r") do file
            for row in rows
                _stage_time_series!(
                    _time_series_kind(row),
                    batch,
                    file,
                    row,
                    lookup_id(ledger, row["owner_uuid"]),
                    report,
                )
            end
        end
        iszero(length(batch)) || InfraStore.add_time_series_bulk!(raw_store, batch)
        _derive_forecasts!(raw_store, rows)
        InfraStore.flush!(raw_store)
        associations = IS.openapi_time_series_association_rows(IS.Store(raw_store))
    finally
        InfraStore.close!(raw_store)
    end
    return destination, associations
end
