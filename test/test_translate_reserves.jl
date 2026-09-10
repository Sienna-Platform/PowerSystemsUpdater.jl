@testset "translate reserves" begin
    using PowerOpenAPIModels: OnlineReserve

    led = PSU.Ledger()
    rep = PSU.ConversionReport()
    ctx = PSU.TranslationContext(led, rep, 100.0)
    PSU.assign_id!(led, "uuid-res")

    raw = Dict{String, Any}(
        "__metadata__" => Dict(
            "type" => "VariableReserve",
            "parameters" => ["ReserveUp"],
        ),
        "internal" => Dict("uuid" => Dict("value" => "uuid-res")),
        "name" => "Reg_Up", "available" => true,
        "time_frame" => 60.0, "requirement" => 0.4, "sustained_time" => 3600.0,
        "max_output_fraction" => 1.0, "max_participation_factor" => 1.0,
        "deployed_fraction" => 0.0,
    )

    out = PSU.translate_component(raw, ctx)
    @test length(out) == 1
    res = out[1]
    @test typeof(res) === OnlineReserve
    @test res.name == "Reg_Up"
    # reserve_direction is a strictly-typed enum wrapper (ReserveDirection)
    # under the OpenAPI 1.1 generator, not a bare String.
    @test res.reserve_direction == PSU.POM.ReserveDirection("UP")
    @test res.requirement == 0.4
    @test res.time_frame == 60.0
    @test isnothing(res.variable)

    @test PSU.reserve_direction(
        Dict("__metadata__" => Dict("parameters" => ["ReserveDown"])),
    ) == "DOWN"

    @testset "both PSY5 types map to OnlineReserve" begin
        led2 = PSU.Ledger()
        rep2 = PSU.ConversionReport()
        ctx2 = PSU.TranslationContext(led2, rep2, 100.0)
        PSU.assign_id!(led2, "uuid-const")
        PSU.assign_id!(led2, "uuid-var")

        raw_const = Dict{String, Any}(
            "__metadata__" =>
                Dict("type" => "ConstantReserve", "parameters" => ["ReserveDown"]),
            "internal" => Dict("uuid" => Dict("value" => "uuid-const")),
            "name" => "Reg_Down",
        )
        raw_var = Dict{String, Any}(
            "__metadata__" =>
                Dict("type" => "VariableReserve", "parameters" => ["ReserveUp"]),
            "internal" => Dict("uuid" => Dict("value" => "uuid-var")),
            "name" => "Reg_Up_Var",
        )

        out_const = PSU.translate_component(raw_const, ctx2)
        out_var = PSU.translate_component(raw_var, ctx2)
        @test typeof(out_const[1]) === OnlineReserve
        @test typeof(out_var[1]) === OnlineReserve
        @test out_const[1].reserve_direction ==
              PSU.POM.ReserveDirection("DOWN")
        @test out_var[1].reserve_direction == PSU.POM.ReserveDirection("UP")
    end

    @testset "ordinary fields survive the mapping" begin
        @test res.sustained_time == 3600.0
        @test res.max_output_fraction == 1.0
        @test res.max_participation_factor == 1.0
        @test res.deployed_fraction == 0.0
    end

    @testset "reserve_direction error paths" begin
        @test_throws PSU.Psy5FormatError PSU.reserve_direction(
            Dict("__metadata__" => Dict("parameters" => String[])),
        )
        @test_throws PSU.Psy5FormatError PSU.reserve_direction(
            Dict("__metadata__" => Dict("parameters" => ["ReserveUp", "ReserveDown"])),
        )
        @test_throws PSU.Psy5FormatError PSU.reserve_direction(
            Dict("__metadata__" => Dict("parameters" => ["ReserveSideways"])),
        )
    end
end
