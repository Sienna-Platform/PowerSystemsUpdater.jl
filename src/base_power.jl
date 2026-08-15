"""
The base power to record on a PSY6 component.

PSY5 stores values in device base, but leaves the base implicit for components that declare
no `base_power` field (`Line`, `ACBus`, `Arc`, `Area`, `LoadZone`, …) — those ride on the
system base. PSY6 requires it recorded per component, so supply the system base there. No
value is ever rescaled.
"""
function base_power_for(raw::AbstractDict, system_base::Real)
    declared = get(raw, "base_power", nothing)
    if isnothing(declared)
        return Float64(system_base)
    end
    return Float64(declared)
end
