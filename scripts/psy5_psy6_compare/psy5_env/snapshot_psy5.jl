# Step 1 of the PSY5 -> PSY6 comparison: load each PSY5 case with PowerSystems 5 and snapshot
# it to `<work_dir>/<case>/psy5_snapshot.json` and `psy5_values.h5`.
#
#   julia --project=scripts/psy5_psy6_compare/psy5_env \
#       scripts/psy5_psy6_compare/psy5_env/snapshot_psy5.jl <work_dir> <case.json>...
#
# Values are read in SYSTEM_BASE, the one unit system both versions can be read in.

using PowerSystems
const PSY = PowerSystems
const IS = PSY.IS

include(joinpath(@__DIR__, "..", "snapshot_common.jl"))
include(joinpath(@__DIR__, "..", "case_layout.jl"))

function getter_for(field::Symbol)
    name = Symbol("get_", field)
    return isdefined(PSY, name) ? getfield(PSY, name) : nothing
end

"""
PSY5 getters convert through the system's units setting; a field without a one-argument
getter is read raw.
"""
function read_field(x::T, field::Symbol) where {T}
    getter = getter_for(field)
    if !isnothing(getter) && hasmethod(getter, Tuple{T})
        return getter(x)
    end
    return getfield(x, field)
end

snapshot_value(x::PSY.Component) = component_ref(type_label(typeof(x)), PSY.get_name(x))

# IS3's `@scoped_enum` types share no supertype to dispatch on, so register a method per enum.
for mod in (PSY, IS), sym in names(mod; all = true)
    label = string(sym)
    if !endswith(label, "Module") || label == "Module"
        continue
    end
    enum_sym = Symbol(chop(label; tail = length("Module")))
    if isdefined(mod, enum_sym) && isdefined(getfield(mod, sym), enum_sym) &&
       getfield(getfield(mod, sym), enum_sym) === getfield(mod, enum_sym)
        @eval snapshot_value(x::$(getfield(mod, enum_sym))) = string(x)
    end
end

function all_components(sys::PSY.System)
    return vcat(
        collect(PSY.get_components(PSY.Component, sys)),
        collect(IS.get_masked_components(PSY.Component, sys.data)),
    )
end

services_of(component::PSY.Device) = PSY.get_services(component)
services_of(::PSY.Component) = ()

# Time series catalog: IS3 lists one key per series.
list_series(owner) = IS.get_time_series_keys(owner)
series_type(key::IS.TimeSeriesKey) = key.time_series_type
series_name(key::IS.TimeSeriesKey) = key.name
read_series(owner, key::IS.TimeSeriesKey) = IS.get_time_series(owner, key)

"""
The factor taking a series' stored values to natural units: its scaling-factor multiplier on
the owner in natural units, or 1.0 without one.
"""
natural_scale(owner, key::IS.TimeSeriesKey) =
    _natural_scale(owner, IS.get_scaling_factor_multiplier(read_series(owner, key)))
_natural_scale(_, ::Nothing) = 1.0
_natural_scale(::PSY.Component, ::Nothing) = 1.0
_natural_scale(owner::PSY.Component, multiplier) =
    PSY.with_units_base(() -> Float64(multiplier(owner)), owner, "NATURAL_UNITS")

function series_metadata(key::IS.StaticTimeSeriesKey)
    return Dict{String, Any}(
        "initial_timestamp" => key.initial_timestamp,
        "resolution" => key.resolution,
        "horizon" => nothing,
        "interval" => nothing,
        "count" => nothing,
        "length" => key.length,
        "features" => key.features,
    )
end

function series_metadata(key::IS.ForecastKey)
    return Dict{String, Any}(
        "initial_timestamp" => key.initial_timestamp,
        "resolution" => key.resolution,
        "horizon" => key.horizon,
        "interval" => key.interval,
        "count" => key.count,
        "length" => nothing,
        "features" => key.features,
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
        run_case_step(work_dir, case, "psy5_snapshot") do dir
            sys = PSY.System(case; time_series_read_only = true)
            PSY.set_units_base_system!(sys, "SYSTEM_BASE")
            write_snapshot(sys, dir, PSY5_SNAPSHOT, PSY5_VALUES)
        end
    end
end

main(ARGS)
