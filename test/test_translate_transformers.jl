using PowerOpenAPIModels: TransformerCircuit, TwoWindingTransformer, ThreeWindingTransformer
using PowerSystemsUpdater: OpenAPI

_is_circuit(::TransformerCircuit) = true
_is_circuit(::OpenAPI.APIModel) = false
_is_two_winding(::TwoWindingTransformer) = true
_is_two_winding(::OpenAPI.APIModel) = false
_is_three_winding(::ThreeWindingTransformer) = true
_is_three_winding(::OpenAPI.APIModel) = false

@testset "winding group -> alpha" begin
    # Sparse and SIGN-INVERTED: GROUP_1 is -30 degrees, not +30.
    @test PSU.winding_group_alpha("GROUP_0") == 0.0
    @test PSU.winding_group_alpha("GROUP_1") ≈ -pi / 6
    @test PSU.winding_group_alpha("GROUP_5") ≈ -5pi / 6
    @test PSU.winding_group_alpha("GROUP_6") ≈ pi
    @test PSU.winding_group_alpha("GROUP_7") ≈ 5pi / 6
    @test PSU.winding_group_alpha("GROUP_11") ≈ pi / 6
    @test_throws PSU.Psy5FormatError PSU.winding_group_alpha("GROUP_3")
end

@testset "all six WindingGroupNumber values, exact radians" begin
    @test PSU.winding_group_alpha("GROUP_0") == 0.0
    @test PSU.winding_group_alpha("GROUP_1") == Float64(-pi / 6)
    @test PSU.winding_group_alpha("GROUP_5") == Float64(-5pi / 6)
    @test PSU.winding_group_alpha("GROUP_6") == Float64(pi)
    @test PSU.winding_group_alpha("GROUP_7") == Float64(5pi / 6)
    @test PSU.winding_group_alpha("GROUP_11") == Float64(pi / 6)

    @test PSU.winding_group_alpha("GROUP_1") < 0.0
    @test PSU.winding_group_alpha("GROUP_11") > 0.0
end

@testset "unknown winding group throws" begin
    @test_throws PSU.Psy5FormatError PSU.winding_group_alpha("GROUP_3")
    @test_throws PSU.Psy5FormatError PSU.winding_group_alpha("")
end

@testset "translate Transformer2W" begin
    using PowerOpenAPIModels: TwoWindingTransformer, TransformerCircuit

    led = PSU.Ledger()
    rep = PSU.ConversionReport()
    ctx = PSU.TranslationContext(led, rep, 100.0)
    PSU.assign_id!(led, "uuid-tx")
    arc_id = PSU.assign_id!(led, "uuid-arc")

    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "Transformer2W"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-tx")),
        "name" => "tx1", "available" => true,
        "arc" => Dict("value" => "uuid-arc"),
        "r" => 0.01, "x" => 0.1,
        "primary_shunt" => Dict("re" => 0.0, "im" => 0.0),
        "rating" => 2.0, "base_power" => 100.0,
        "base_voltage_primary" => 230.0, "base_voltage_secondary" => 115.0,
        "winding_group_number" => "GROUP_1",
        "active_power_flow" => 0.0, "reactive_power_flow" => 0.0,
    )

    out = PSU.translate_component(raw, ctx)
    @test length(out) == 2
    circuit = only(filter(_is_circuit, out))
    transformer = only(filter(_is_two_winding, out))

    @test transformer.id == 1
    @test transformer.name == "tx1"
    @test transformer.circuit == circuit.id
    @test circuit.id != transformer.id          # synthesized id, distinct
    @test circuit.arc == arc_id
    @test circuit.r == 0.01
    @test circuit.x == 0.1
    @test circuit.available
    @test circuit.tap == 1.0                    # Transformer2W has no tap
    @test circuit.alpha ≈ -pi / 6               # from GROUP_1
    @test circuit.base_power == 100.0

    @testset "field survival" begin
        @test circuit.r == 0.01
        @test circuit.x == 0.1
        @test circuit.rating == 2.0
        @test circuit.base_power == 100.0
        @test circuit.base_voltage_primary == 230.0
        @test circuit.base_voltage_secondary == 115.0
    end

    @testset "ids are non-nothing and distinct" begin
        @test !isnothing(circuit.id)
        @test !isnothing(transformer.id)
        @test circuit.id != transformer.id
    end
end

@testset "translate TapTransformer" begin
    using PowerOpenAPIModels: TwoWindingTransformer, TransformerCircuit

    led = PSU.Ledger()
    rep = PSU.ConversionReport()
    ctx = PSU.TranslationContext(led, rep, 100.0)
    PSU.assign_id!(led, "uuid-tap")
    arc_id = PSU.assign_id!(led, "uuid-arc-tap")

    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "TapTransformer"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-tap")),
        "name" => "tap1", "available" => true,
        "arc" => Dict("value" => "uuid-arc-tap"),
        "r" => 0.02, "x" => 0.2, "tap" => 1.05,
        "primary_shunt" => Dict("re" => 0.0, "im" => 0.0),
        "rating" => 3.0, "base_power" => 100.0,
        "base_voltage_primary" => 138.0, "base_voltage_secondary" => 69.0,
        "winding_group_number" => "GROUP_11",
        "active_power_flow" => 0.0, "reactive_power_flow" => 0.0,
    )

    out = PSU.translate_component(raw, ctx)
    circuit = only(filter(_is_circuit, out))
    transformer = only(filter(_is_two_winding, out))

    @test circuit.tap == 1.05                   # TapTransformer's own tap, not the default
    @test circuit.alpha ≈ pi / 6                 # from GROUP_11
    @test circuit.arc == arc_id

    @testset "ids are non-nothing and distinct" begin
        @test !isnothing(circuit.id)
        @test !isnothing(transformer.id)
        @test circuit.id != transformer.id
    end

    @testset "field survival" begin
        @test circuit.r == 0.02
        @test circuit.x == 0.2
        @test circuit.rating == 3.0
        @test circuit.base_power == 100.0
        @test circuit.base_voltage_primary == 138.0
        @test circuit.base_voltage_secondary == 69.0
    end
end

@testset "translate PhaseShiftingTransformer" begin
    using PowerOpenAPIModels: TransformerCircuit

    led = PSU.Ledger()
    rep = PSU.ConversionReport()
    ctx = PSU.TranslationContext(led, rep, 100.0)
    PSU.assign_id!(led, "uuid-pst")
    arc_id = PSU.assign_id!(led, "uuid-arc")

    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "PhaseShiftingTransformer"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-pst")),
        "name" => "pst1", "available" => true,
        "arc" => Dict("value" => "uuid-arc"),
        "r" => 0.01, "x" => 0.1, "tap" => 1.02, "α" => 0.05,
        "base_power" => 100.0,
        "active_power_flow" => 0.0, "reactive_power_flow" => 0.0,
    )

    out = PSU.translate_component(raw, ctx)
    circuit = only(filter(_is_circuit, out))
    transformer = only(filter(_is_two_winding, out))
    @test circuit.tap == 1.02
    @test circuit.alpha == 0.05        # already radians, copied verbatim

    @testset "ids are non-nothing and distinct" begin
        @test !isnothing(circuit.id)
        @test !isnothing(transformer.id)
        @test circuit.id != transformer.id
    end
end

@testset "PhaseShiftingTransformer alpha: negative value, no sign flip" begin
    led = PSU.Ledger()
    rep = PSU.ConversionReport()
    ctx = PSU.TranslationContext(led, rep, 100.0)
    PSU.assign_id!(led, "uuid-pst-neg")
    PSU.assign_id!(led, "uuid-arc-neg")

    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "PhaseShiftingTransformer"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-pst-neg")),
        "name" => "pst_neg", "available" => true,
        "arc" => Dict("value" => "uuid-arc-neg"),
        "r" => 0.01, "x" => 0.1, "tap" => 0.98, "α" => -0.37,
        "base_power" => 100.0,
        "active_power_flow" => 0.0, "reactive_power_flow" => 0.0,
    )

    out = PSU.translate_component(raw, ctx)
    circuit = only(filter(_is_circuit, out))
    @test circuit.alpha == -0.37
end

@testset "magnetizing_shunt: re/im translated to real/imag" begin
    led = PSU.Ledger()
    rep = PSU.ConversionReport()
    ctx = PSU.TranslationContext(led, rep, 100.0)
    PSU.assign_id!(led, "uuid-shunt")
    PSU.assign_id!(led, "uuid-arc-shunt")

    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "Transformer2W"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-shunt")),
        "name" => "tx_shunt", "available" => true,
        "arc" => Dict("value" => "uuid-arc-shunt"),
        "r" => 0.01, "x" => 0.1,
        "primary_shunt" => Dict("re" => 0.001, "im" => 0.02),
        "base_power" => 100.0,
        "winding_group_number" => "GROUP_0",
        "active_power_flow" => 0.0, "reactive_power_flow" => 0.0,
    )

    out = PSU.translate_component(raw, ctx)
    transformer = only(filter(_is_two_winding, out))
    @test transformer.magnetizing_shunt.real == 0.001
    @test transformer.magnetizing_shunt.imag == 0.02
end
