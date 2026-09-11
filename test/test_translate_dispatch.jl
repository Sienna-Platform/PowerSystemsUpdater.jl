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

    @testset "root skip wins over cascade" begin
        led4 = PSU.Ledger()
        rep4 = PSU.ConversionReport()
        ctx4 = PSU.TranslationContext(led4, rep4, 100.0)

        PSU.assign_id!(led4, "uuid-gadget2")
        raw_gadget2 = Dict{String, Any}(
            "__metadata__" => Dict("type" => "Gadget"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-gadget2")),
        )
        PSU.translate_component(raw_gadget2, ctx4)

        PSU.assign_id!(led4, "uuid-widget2")
        raw_widget2 = Dict{String, Any}(
            "__metadata__" => Dict("type" => "Widget"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-widget2")),
            "area" => Dict("value" => "uuid-gadget2"),
        )
        out_widget2 = PSU.translate_component(raw_widget2, ctx4)
        @test isempty(out_widget2)
        @test rep4.unmapped_types["Widget"] == 1
        @test !haskey(rep4.cascaded_skips, "Widget")
        @test PSU.is_skipped(led4, "uuid-widget2")
    end

    @testset "base_power synthesized only where the model declares it" begin
        led3 = PSU.Ledger()
        rep3 = PSU.ConversionReport()
        ctx3 = PSU.TranslationContext(led3, rep3, 100.0)

        PSU.assign_id!(led3, "uuid-bus3")
        raw_bus3 = Dict{String, Any}(
            "__metadata__" => Dict("type" => "ACBus"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-bus3")),
            "name" => "nodeD", "number" => 3, "available" => true,
            "bustype" => "REF", "base_voltage" => 230.0,
        )
        PSU.translate_component(raw_bus3, ctx3)

        # A minimal but schema-valid ThermalStandard: every PSY6-required field
        # (active_power, active_power_limits, operation_cost, rating, reactive_power,
        # status) needs a value, since OpenAPI.jl 1.x's immutable structs reject missing
        # required keywords instead of defaulting them like the pre-migration model
        # runtime did. `base_power` is deliberately absent — that is what this test checks.
        PSU.assign_id!(led3, "uuid-gen")
        raw_gen = Dict{String, Any}(
            "__metadata__" => Dict("type" => "ThermalStandard"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-gen")),
            "name" => "gen1",
            "available" => true,
            "status" => true,
            "bus" => Dict("value" => "uuid-bus3"),
            "active_power" => 0.0,
            "reactive_power" => 0.0,
            "rating" => 0.0,
            "active_power_limits" => Dict{String, Any}("min" => 0.0, "max" => 0.0),
            "operation_cost" => Dict{String, Any}(
                "__metadata__" => Dict("type" => "ThermalGenerationCost"),
                "fixed" => 0.0,
                "shut_down" => 0.0,
                "start_up" => 0.0,
                "variable" => Dict{String, Any}(
                    "__metadata__" => Dict("type" => "CostCurve"),
                    "power_units" => "NATURAL_UNITS",
                    "value_curve" => Dict{String, Any}(
                        "__metadata__" => Dict("type" => "InputOutputCurve"),
                        "function_data" => Dict{String, Any}(
                            "__metadata__" => Dict("type" => "LinearFunctionData"),
                            "constant_term" => 0.0,
                            "proportional_term" => 0.0,
                        ),
                    ),
                    "vom_cost" => Dict{String, Any}(
                        "__metadata__" => Dict("type" => "InputOutputCurve"),
                        "function_data" => Dict{String, Any}(
                            "__metadata__" => Dict("type" => "LinearFunctionData"),
                            "constant_term" => 0.0,
                            "proportional_term" => 0.0,
                        ),
                    ),
                ),
            ),
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
        @test PSU.has_translator("Line")
        @test PSU.has_translator("ThermalStandard")
        for name in
            ("Arc", "ConstantReserve", "VariableReserve", "Transformer2W", "TapTransformer",
            "PhaseShiftingTransformer", "Transformer3W")
            @test PSU.has_translator(name)
        end
        @test !PSU.has_translator("NotARealType")
    end

    @testset "DIRECT_TYPES" begin
        @test length(PSU.DIRECT_TYPES) == 22
        @test !(:Arc in PSU.DIRECT_TYPES)
        @test !(:ExponentialLoad in PSU.DIRECT_TYPES)
        @test !(:FixedAdmittance in PSU.DIRECT_TYPES)
        @test !(:TwoTerminalGenericHVDCLine in PSU.DIRECT_TYPES)
        @test !(:TwoTerminalLCCLine in PSU.DIRECT_TYPES)
        @test !(:TwoTerminalVSCLine in PSU.DIRECT_TYPES)
        @test !(:InterconnectingConverter in PSU.DIRECT_TYPES)
        @test !(:HydroPumpTurbine in PSU.DIRECT_TYPES)
        for name in PSU.DIRECT_TYPES
            @test isdefined(PSU.POM, name)
        end
    end

    @testset "Arc: from/to renamed to from_id/to_id" begin
        led5 = PSU.Ledger()
        rep5 = PSU.ConversionReport()
        ctx5 = PSU.TranslationContext(led5, rep5, 100.0)

        PSU.assign_id!(led5, "uuid-arc-from")
        PSU.assign_id!(led5, "uuid-arc-to")
        PSU.assign_id!(led5, "uuid-arc")
        raw_arc = Dict{String, Any}(
            "__metadata__" => Dict("type" => "Arc"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-arc")),
            "from" => Dict("value" => "uuid-arc-from"),
            "to" => Dict("value" => "uuid-arc-to"),
        )
        out_arc = PSU.translate_component(raw_arc, ctx5)
        @test length(out_arc) == 1
        arc = out_arc[1]
        @test typeof(arc) === PSU.POM.Arc
        @test arc.from_id == PSU.lookup_id(led5, "uuid-arc-from")
        @test arc.to_id == PSU.lookup_id(led5, "uuid-arc-to")
        @test isempty(rep5.unmapped_fields)
    end

    @testset "ExponentialLoad: α/β renamed to alpha/beta" begin
        led6 = PSU.Ledger()
        rep6 = PSU.ConversionReport()
        ctx6 = PSU.TranslationContext(led6, rep6, 100.0)

        PSU.assign_id!(led6, "uuid-bus6")
        raw_bus6 = Dict{String, Any}(
            "__metadata__" => Dict("type" => "ACBus"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-bus6")),
            "name" => "nodeE", "number" => 6, "available" => true,
            "bustype" => "REF", "base_voltage" => 230.0,
        )
        PSU.translate_component(raw_bus6, ctx6)

        PSU.assign_id!(led6, "uuid-expload")
        raw_expload = Dict{String, Any}(
            "__metadata__" => Dict("type" => "ExponentialLoad"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-expload")),
            "name" => "load1", "available" => true,
            "bus" => Dict("value" => "uuid-bus6"),
            "active_power" => 1.0, "reactive_power" => 0.5,
            "α" => 1.5, "β" => 2.0,
            "max_active_power" => 2.0, "max_reactive_power" => 1.0,
            "conformity" => "CONFORMING",
        )
        out_expload = PSU.translate_component(raw_expload, ctx6)
        @test length(out_expload) == 1
        load = out_expload[1]
        @test typeof(load) === PSU.POM.ExponentialLoad
        @test load.alpha == 1.5
        @test load.beta == 2.0
        @test isempty(rep6.unmapped_fields)
    end
end
