@testset "translate MonitoredLine" begin
    using PowerOperationsOpenAPIModels: Line

    led = PSU.Ledger()
    rep = PSU.ConversionReport()
    ctx = PSU.TranslationContext(led, rep, 100.0)
    PSU.assign_id!(led, "uuid-ml")
    arc_id = PSU.assign_id!(led, "uuid-arc")

    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "MonitoredLine"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-ml")),
        "name" => "ml1", "available" => true,
        "arc" => Dict("value" => "uuid-arc"),
        "active_power_flow" => 0.0, "reactive_power_flow" => 0.0,
        "r" => 0.01, "x" => 0.1,
        "b" => Dict("from" => 0.0, "to" => 0.0),
        "flow_limits" => Dict("from_to" => 1.5, "to_from" => 1.2),
        "rating" => 2.0,
        "angle_limits" => Dict("min" => -0.5, "max" => 0.5),
    )

    out = PSU.translate_component(raw, ctx)
    line = only(out)
    @test typeof(line) === Line
    @test line.id == 1
    @test line.arc == arc_id
    @test line.rating == 2.0
    @test line.base_power == 100.0
    limit = line.operational_flow_limit
    @test limit.from_to_max == 1.5
    @test limit.to_from_max == 1.2
    @test iszero(limit.from_to_min)
    @test iszero(limit.to_from_min)
    @test isempty(rep.unmapped_fields)
    @test haskey(raw, "flow_limits")
end
