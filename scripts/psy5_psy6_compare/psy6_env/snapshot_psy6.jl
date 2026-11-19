# Step 3 of the PSY5 -> PSY6 comparison: load each converted bundle with PowerSystems 6 and
# snapshot it to `<work_dir>/<case>/psy6_snapshot.json` and `psy6_values.h5`.
#
#   julia --project=scripts/psy5_psy6_compare/psy6_env \
#       scripts/psy5_psy6_compare/psy6_env/snapshot_psy6.jl <work_dir> <case.json>...
#
# The case arguments are the PSY5 files; only their names are used, to find the bundle.

using PowerSystems
const PSY = PowerSystems
const IS = PSY.IS

include(joinpath(@__DIR__, "..", "snapshot_common.jl"))
include(joinpath(@__DIR__, "..", "case_layout.jl"))

function getter_for(field::Symbol)
    name = Symbol("get_", field)
    return isdefined(PSY, name) ? getfield(PSY, name) : nothing
end

# Unitful units, not the `SU` marker, which the generated getters have no method for. Rates
# (ramp limits) refuse a bare power basis; PSY5's SYSTEM_BASE ramps are per unit per minute.
const SYSTEM_BASE_UNITS = (u"SU", u"SU/minute")

"""
Read unit-bearing fields in system base, to match the PSY5 snapshot. A getter refuses a unit
of the wrong kind with an `ArgumentError`, so each is tried in turn; base values refuse them
all and are read in natural units, as PSY5 returns them.
"""
function read_field(x::T, field::Symbol) where {T}
    getter = getter_for(field)
    if isnothing(getter)
        return getfield(x, field)
    end
    for units in SYSTEM_BASE_UNITS
        if hasmethod(getter, Tuple{T, typeof(units)})
            try
                return getter(x, units)
            catch e
                e isa ArgumentError || rethrow()
            end
        end
    end
    if hasmethod(getter, Tuple{T})
        return getter(x)
    end
    return getfield(x, field)
end

snapshot_value(x::PSY.Component) = component_ref(type_label(typeof(x)), PSY.get_name(x))

function all_components(sys::PSY.System)
    return vcat(
        collect(PSY.get_components(PSY.Component, sys)),
        collect(IS.get_masked_components(PSY.Component, sys.data)),
    )
end

services_of(component::PSY.Device) = PSY.get_services(component)
services_of(::PSY.Component) = ()

# Time series catalog: IS4 lists one metadata row per series; its key names the stored type.
list_series(owner) = IS.list_time_series_metadata(owner)
series_type(row::IS.TimeSeriesMetadata) =
    IS.get_time_series_type(IS.get_time_series_key(row))
series_name(row::IS.TimeSeriesMetadata) = row.name
read_series(owner, row::IS.TimeSeriesMetadata) =
    IS.get_time_series(owner, IS.get_time_series_key(row))

"""
The factor taking a series' stored values to natural units, as PowerSystems reads it from the
series' units labels; 1.0 for a series without labels.
"""
function natural_scale(owner, row::IS.TimeSeriesMetadata)
    quantity = PSY._ts_quantity(row)
    if isnothing(quantity)
        return 1.0
    end
    kind = PSY.TIME_SERIES_QUANTITIES[quantity]
    return PSY._ts_conversion_factor(
        owner,
        kind,
        PSY._ts_source_units(row),
        PSY._ts_natural_unit(kind),
    )
end

# IS4 may fill both `length` and the forecast columns; only one applies, as in PSY5's keys.
_length(::IS.TimeSeriesMetadata{<:IS.Forecast}) = nothing
_length(row::IS.TimeSeriesMetadata) = row.length
_forecast_field(::IS.TimeSeriesMetadata{<:IS.Forecast}, value) = value
_forecast_field(::IS.TimeSeriesMetadata, _) = nothing

"""
Every series' catalog row by association id, so a `TimeSeriesKey` held in a field
(`FuelCurve.fuel_cost_time_series`) is recorded as the series it names. Filled by
`index_series!`.
"""
const SERIES_BY_ASSOCIATION = Dict{Int, IS.TimeSeriesMetadata}()

function index_series!(sys::PSY.System)
    empty!(SERIES_BY_ASSOCIATION)
    owners = Iterators.flatten((all_components(sys), supplemental_attributes(sys)))
    for owner in owners, row in attempt(() -> list_series(owner))
        key = IS.get_time_series_key(row)
        SERIES_BY_ASSOCIATION[IS.get_association_id(key)] = row
    end
    return nothing
end

"""
A key held in a field, recorded as PSY5's `ForecastKey`/`StaticTimeSeriesKey`; one naming no
indexed series keeps its id.
"""
function snapshot_value(key::IS.TimeSeriesKey)
    id = IS.get_association_id(key)
    if !haskey(SERIES_BY_ASSOCIATION, id)
        return Dict{String, Any}("__type__" => "TimeSeriesKey", "association_id" => id)
    end
    row = SERIES_BY_ASSOCIATION[id]
    forecast = !isnothing(_forecast_field(row, row.count))
    record = Dict{String, Any}(
        "__type__" => forecast ? "ForecastKey" : "StaticTimeSeriesKey",
        "name" => series_name(row),
        "time_series_type" => string(nameof(series_type(row))),
    )
    for (k, v) in series_metadata(row)
        if forecast ? k != "length" : !(k in ("horizon", "interval", "count"))
            record[k] = snapshot_value(v)
        end
    end
    return record
end

function series_metadata(row::IS.TimeSeriesMetadata)
    return Dict{String, Any}(
        "initial_timestamp" => row.initial_timestamp,
        "resolution" => row.resolution,
        "horizon" => _forecast_field(row, row.horizon),
        "interval" => _forecast_field(row, row.interval),
        "count" => _forecast_field(row, row.count),
        "length" => _length(row),
        "features" => row.features,
    )
end

supplemental_attributes(sys::PSY.System) =
    PSY.get_supplemental_attributes(PSY.SupplementalAttribute, sys)
associated_components(sys::PSY.System, attribute) =
    PSY.get_associated_components(sys, attribute)

function system_header(sys::PSY.System)
    return Dict{String, Any}(
        "psy_version" => string(pkgversion(PSY)),
        "name" => attempt(() -> snapshot_value(PSY.get_name(sys))),
        "description" => attempt(() -> snapshot_value(PSY.get_description(sys))),
        "base_power" => attempt(() -> snapshot_value(PSY.get_base_power(sys))),
        "frequency" => attempt(() -> snapshot_value(PSY.get_frequency(sys))),
    )
end

function main(args)
    work_dir, cases = parse_step_args(args)
    for case in cases
        bundle = joinpath(case_dir(work_dir, case), PSY6_BUNDLE)
        # A failed conversion can leave a partial bundle; loading it would only add a second,
        # misleading error.
        if !isdir(bundle) ||
           isfile(joinpath(case_dir(work_dir, case), error_file("convert")))
            clear_step!(case_dir(work_dir, case), "psy6_snapshot")
            @warn "no converted bundle; skipping" case = case_name(case)
            continue
        end
        run_case_step(work_dir, case, "psy6_snapshot") do dir
            # Writable, as a user would load it: read-only fails for any system with
            # supplemental attributes, whose associations the loader writes to the store.
            sys = PSY.from_file(bundle)
            index_series!(sys)
            write_snapshot(sys, dir, PSY6_SNAPSHOT, PSY6_VALUES)
        end
    end
end

main(ARGS)
