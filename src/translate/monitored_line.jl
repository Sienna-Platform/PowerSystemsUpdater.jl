"""
PSY6 has no `MonitoredLine`. PSY5 `flow_limits` (`from_to`, `to_from`) are maximum flows in
each direction and become `operational_flow_limit` on a `Line`, in the same units as
`rating`. PSY5 has no minimum flow, so both minimums are 0.0, the lowest value the schema
allows.
"""
function _operational_flow_limit(raw::AbstractDict)
    limits = raw["flow_limits"]
    return Dict{String, Any}(
        "from_to_min" => 0.0,
        "from_to_max" => Float64(limits["from_to"]),
        "to_from_min" => 0.0,
        "to_from_max" => Float64(limits["to_from"]),
    )
end

function translate(::Val{:MonitoredLine}, raw::AbstractDict, ctx::TranslationContext)
    line_fields = copy(raw)
    delete!(line_fields, "flow_limits")
    extra = Dict{Symbol, Any}(
        :id => lookup_id(ctx.ledger, component_uuid(raw)),
        :base_power => base_power_for(raw, ctx.system_base),
        :power_units => "COMPONENT_BASE",
        :operational_flow_limit => _operational_flow_limit(raw),
    )
    kwargs = build_kwargs(POOM.Line, line_fields, ctx.ledger, ctx.report; extra = extra)
    return ICOM.APIModel[POOM.Line(; kwargs...)]
end
