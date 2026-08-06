@testset "translate dispatch" begin
    using PowerOpenAPIModels: ACBus, ThermalStandard

    led = PSU.Ledger()
    rep = PSU.ConversionReport()
    ctx = PSU.TranslationContext(led, rep, 100.0)

    PSU.assign_id!(led, "uuid-bus")
    raw_bus = Dict{String, Any}(
        "__metadata__" => Dict("type" => "ACBus"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-bus")),
        "name" => "nodeA", "number" => 1, "available" => true,
        "bustype" => "REF", "base_voltage" => 230.0,
    )
    out = PSU.translate_component(raw_bus, ctx)
    @test length(out) == 1
    @test typeof(out[1]) === ACBus
    @test out[1].id == 1
    @test out[1].name == "nodeA"

    PSU.assign_id!(led, "uuid-widget")
    raw_widget = Dict{String, Any}(
        "__metadata__" => Dict("type" => "Widget"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-widget")),
    )
    @test isempty(PSU.translate_component(raw_widget, ctx))
    @test rep.unmapped_types["Widget"] == 1
    @test PSU.is_skipped(led, "uuid-widget")

    @test PSU.has_translator("Line")
    @test !PSU.has_translator("Widget")

    @testset "cascaded skip" begin
        led2 = PSU.Ledger()
        rep2 = PSU.ConversionReport()
        ctx2 = PSU.TranslationContext(led2, rep2, 100.0)

        PSU.assign_id!(led2, "uuid-gadget")
        raw_gadget = Dict{String, Any}(
            "__metadata__" => Dict("type" => "Gadget"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-gadget")),
        )
        PSU.translate_component(raw_gadget, ctx2)

        PSU.assign_id!(led2, "uuid-dependent")
        raw_dependent = Dict{String, Any}(
            "__metadata__" => Dict("type" => "ACBus"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-dependent")),
            "name" => "nodeB",
            "area" => Dict("value" => "uuid-gadget"),
        )
        out_dependent = PSU.translate_component(raw_dependent, ctx2)
        @test isempty(out_dependent)
        @test rep2.cascaded_skips["ACBus"] == 1
        @test PSU.is_skipped(led2, "uuid-dependent")
    end

    @testset "base_power synthesized only where the model declares it" begin
        led3 = PSU.Ledger()
        rep3 = PSU.ConversionReport()
        ctx3 = PSU.TranslationContext(led3, rep3, 100.0)

        PSU.assign_id!(led3, "uuid-gen")
        raw_gen = Dict{String, Any}(
            "__metadata__" => Dict("type" => "ThermalStandard"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-gen")),
            "name" => "gen1",
        )
        out_gen = PSU.translate_component(raw_gen, ctx3)
        @test length(out_gen) == 1
        @test typeof(out_gen[1]) === ThermalStandard
        @test out_gen[1].base_power == 100.0

        PSU.assign_id!(led3, "uuid-bus2")
        raw_bus2 = Dict{String, Any}(
            "__metadata__" => Dict("type" => "ACBus"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-bus2")),
            "name" => "nodeC", "number" => 2, "available" => true,
            "bustype" => "REF", "base_voltage" => 230.0,
        )
        out_bus2 = PSU.translate_component(raw_bus2, ctx3)
        @test length(out_bus2) == 1
        @test typeof(out_bus2[1]) === ACBus
        @test !(:base_power in fieldnames(ACBus))
    end

    @testset "has_translator" begin
        @test PSU.has_translator("ThermalStandard")
        for name in
            ("ConstantReserve", "VariableReserve", "Transformer2W", "TapTransformer",
            "PhaseShiftingTransformer", "Transformer3W")
            @test PSU.has_translator(name)
        end
        @test !PSU.has_translator("NotARealType")
    end

    @testset "DIRECT_TYPES" begin
        @test length(PSU.DIRECT_TYPES) == 29
        for name in PSU.DIRECT_TYPES
            @test isdefined(PSU.POM, name)
        end
    end
end
