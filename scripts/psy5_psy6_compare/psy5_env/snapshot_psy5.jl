# Step 1 of the PSY5 -> PSY6 comparison: deserialize each PSY5 case with PowerSystems 5 and
# write its snapshot to `<work_dir>/<case>/psy5_snapshot.json`, with its time series values
# in `psy5_values.h5`.
#
#   julia --project=scripts/psy5_psy6_compare/psy5_env \
#       scripts/psy5_psy6_compare/psy5_env/snapshot_psy5.jl <work_dir> <case.json>...
#
# Values are read in SYSTEM_BASE: PSY6 dropped it from the document but still offers it at
# every accessor (`SU`), so it is the one unit system both versions can be read in.

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
PSY5 getters convert through the system's units setting, so a getter with a one-argument
method is the unit-converted read. Fields without one are read raw.
"""
function read_field(x::T, field::Symbol) where {T}
    getter = getter_for(field)
    if !isnothing(getter) && hasmethod(getter, Tuple{T})
        return getter(x)
    end
    return getfield(x, field)
end

snapshot_value(x::PSY.Component) = component_ref(type_label(typeof(x)), PSY.get_name(x))

# IS3's `@scoped_enum` gives each enum its own struct inside a `<Name>Module`, with no common
# supertype to dispatch on, so register a method per enum. Each prints as its bare label,
# matching PSY6's EnumX enums.
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
