# Step 3 of the PSY5 -> PSY6 comparison: deserialize each converted bundle with PowerSystems 6
# and write its snapshot to `<work_dir>/<case>/psy6_snapshot.json`, with its time series
# values in `psy6_values.h5`.
#
#   julia --project=scripts/psy5_psy6_compare/psy6_env \
#       scripts/psy5_psy6_compare/psy6_env/snapshot_psy6.jl <work_dir> <case.json>...
#
# The case arguments are the original PSY5 files; only their names are used, to find the
# bundle step 2 wrote.

using PowerSystems
const PSY = PowerSystems
const IS = PSY.IS

include(joinpath(@__DIR__, "..", "snapshot_common.jl"))
include(joinpath(@__DIR__, "..", "case_layout.jl"))

function getter_for(field::Symbol)
    name = Symbol("get_", field)
    return isdefined(PSY, name) ? getfield(PSY, name) : nothing
end

# Unitful units, not the exported `SU` marker: PSY6's generated getters convert through
# `get_value(..., ::Unitful.Units)` and have no method for the marker type. Rates (ramp
# limits) refuse a bare power basis and take a per-time one; PSY5's SYSTEM_BASE ramps are
# per unit per minute.
const SYSTEM_BASE_UNITS = (u"SU", u"SU/minute")

"""
PSY6 getters take their units explicitly. Read unit-bearing fields in system base to match
the PSY5 snapshot. A getter refuses a unit of the wrong kind with an `ArgumentError`, so each
system-base unit is tried in turn; base values (`base_power`, `base_voltage`) refuse them all
and are read in natural units, as PSY5 returns them.
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

# Time series catalog: IS4 lists one metadata row per series. The row's key names the stored
# type; reading a `DeterministicSingleTimeSeries` returns a materialized `Deterministic`, so
# the type is never taken from the read series.
list_series(owner) = IS.list_time_series_metadata(owner)
series_type(row::IS.TimeSeriesMetadata) =
    IS.get_time_series_type(IS.get_time_series_key(row))
series_name(row::IS.TimeSeriesMetadata) = row.name
read_series(owner, row::IS.TimeSeriesMetadata) =
    IS.get_time_series(owner, IS.get_time_series_key(row))

# A forecast's length is the count of its windows, not a series length: IS4 may fill both
# columns, but only one applies, as in PSY5's keys.
_length(::IS.TimeSeriesMetadata{<:IS.Forecast}) = nothing
_length(row::IS.TimeSeriesMetadata) = row.length
_forecast_field(::IS.TimeSeriesMetadata{<:IS.Forecast}, value) = value
_forecast_field(::IS.TimeSeriesMetadata, _) = nothing

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
        if !isdir(bundle)
            # Conversion failed or never ran; an older snapshot must not stand in for this one.
            clear_step!(case_dir(work_dir, case), "psy6_snapshot")
            @warn "no converted bundle; skipping" case = case_name(case)
            continue
        end
        run_case_step(work_dir, case, "psy6_snapshot") do dir
            sys = PSY.from_file(bundle; time_series_read_only = true)
            write_snapshot(sys, dir, PSY6_SNAPSHOT, PSY6_VALUES)
        end
    end
end

main(ARGS)
