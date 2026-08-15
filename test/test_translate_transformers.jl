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

@testset "UNDEFINED winding group takes the schema default" begin
    @test PSU.winding_group_alpha("UNDEFINED") == 0.0
    @test_throws PSU.Psy5FormatError PSU.winding_group_alpha("GROUP_3")
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
        "primary_shunt" => Dict("real" => 0.0, "imag" => 0.0),
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
        @test circuit.rating == 2.0
        @test circuit.base_voltage_primary == 230.0
        @test circuit.base_voltage_secondary == 115.0
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
        "primary_shunt" => Dict("real" => 0.0, "imag" => 0.0),
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

@testset "magnetizing_shunt: real/imag survive" begin
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
        "primary_shunt" => Dict("real" => 0.001, "imag" => 0.02),
        "base_power" => 100.0,
        "winding_group_number" => "GROUP_0",
        "active_power_flow" => 0.0, "reactive_power_flow" => 0.0,
    )

    out = PSU.translate_component(raw, ctx)
    transformer = only(filter(_is_two_winding, out))
    @test transformer.magnetizing_shunt.real == 0.001
    @test transformer.magnetizing_shunt.imag == 0.02
end

@testset "unmapped fields are recorded, not silently dropped" begin
    led = PSU.Ledger()
    rep = PSU.ConversionReport()
    ctx = PSU.TranslationContext(led, rep, 100.0)
    PSU.assign_id!(led, "uuid-tap-limits")
    PSU.assign_id!(led, "uuid-arc-tap-limits")

    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "TapTransformer"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-tap-limits")),
        "name" => "tap_limits1", "available" => true,
        "arc" => Dict("value" => "uuid-arc-tap-limits"),
        "r" => 0.02, "x" => 0.2, "tap" => 1.0,
        "primary_shunt" => Dict("real" => 0.0, "imag" => 0.0),
        "base_power" => 100.0,
        "winding_group_number" => "UNDEFINED",
        "tap_limits" => Dict("min" => 0.9, "max" => 1.1),
        "active_power_flow" => 0.0, "reactive_power_flow" => 0.0,
    )

    PSU.translate_component(raw, ctx)
    @test rep.unmapped_fields[("TapTransformer", "tap_limits")] == 1
end

@testset "translate Transformer3W" begin
    using PowerOpenAPIModels: ThreeWindingTransformer, TransformerCircuit

    led = PSU.Ledger()
    rep = PSU.ConversionReport()
    ctx = PSU.TranslationContext(led, rep, 100.0)
    PSU.assign_id!(led, "uuid-3w")
    star = PSU.assign_id!(led, "uuid-star")
    pa = PSU.assign_id!(led, "uuid-parc")
    sa = PSU.assign_id!(led, "uuid-sarc")
    ta = PSU.assign_id!(led, "uuid-tarc")

    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "Transformer3W"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-3w")),
        "name" => "HV-LV-MV", "available" => true,
        "star_bus" => Dict("value" => "uuid-star"),
        "primary_star_arc" => Dict("value" => "uuid-parc"),
        "secondary_star_arc" => Dict("value" => "uuid-sarc"),
        "tertiary_star_arc" => Dict("value" => "uuid-tarc"),
        "r_primary" => 0.0022, "x_primary" => 0.0021,
        "r_secondary" => 0.0012, "x_secondary" => 0.0021,
        "r_tertiary" => 0.0018, "x_tertiary" => 0.0002,
        "r_12" => 0.0034, "x_12" => 0.0042,
        "r_23" => 0.003, "x_23" => 0.0002,
        "r_13" => 0.004, "x_13" => 0.0002,
        "base_power_12" => 100.0, "base_power_23" => 100.0, "base_power_13" => 100.0,
        "primary_turns_ratio" => 1.0, "secondary_turns_ratio" => 1.0,
        "tertiary_turns_ratio" => 1.0,
        "available_primary" => true, "available_secondary" => true,
        "available_tertiary" => true,
        "rating_primary" => 10.0, "rating_secondary" => 10.0, "rating_tertiary" => 10.0,
        "base_voltage_primary" => 110.0, "base_voltage_secondary" => 11.0,
        "base_voltage_tertiary" => 33.0,
        "g" => 0.0, "b" => 0.0,
        "active_power_flow_primary" => 0.0, "reactive_power_flow_primary" => 0.0,
        "active_power_flow_secondary" => 0.0, "reactive_power_flow_secondary" => 0.0,
        "active_power_flow_tertiary" => 0.0, "reactive_power_flow_tertiary" => 0.0,
    )

    out = PSU.translate_component(raw, ctx)
    @test length(out) == 4

    tx = only(filter(_is_three_winding, out))
    circuits = filter(_is_circuit, out)
    @test length(circuits) == 3
    @test tx.star_bus == star
    @test Set([tx.primary_circuit, tx.secondary_circuit, tx.tertiary_circuit]) ==
          Set(c.id for c in circuits)

    # THE TRAP: PSY5 1-3 becomes PSY6 3-1. Index order flips.
    @test tx.r_31 == 0.004
    @test tx.x_31 == 0.0002
    @test tx.base_power_31 == 100.0
    @test tx.r_12 == 0.0034
    @test tx.r_23 == 0.003

    primary = only(c for c in circuits if c.arc == pa)
    @test primary.r == 0.0022
    @test primary.x == 0.0021
    @test primary.rating == 10.0
    @test primary.base_voltage_primary == 110.0

    @testset "index flip: pairwise pairs stay distinct, not just correctly named" begin
        @test tx.r_12 != tx.r_23
        @test tx.r_23 != tx.r_31
        @test tx.r_12 != tx.r_31
    end

    @testset "per-winding field routing: each circuit keeps its own values" begin
        secondary = only(c for c in circuits if c.arc == sa)
        tertiary = only(c for c in circuits if c.arc == ta)

        @test secondary.r == 0.0012
        @test secondary.x == 0.0021
        @test secondary.rating == 10.0
        @test secondary.base_voltage_primary == 11.0

        @test tertiary.r == 0.0018
        @test tertiary.x == 0.0002
        @test tertiary.rating == 10.0
        @test tertiary.base_voltage_primary == 33.0

        # Distinguishing values so a wrong-winding mix-up cannot pass silently.
        @test primary.r != secondary.r != tertiary.r
        @test primary.base_voltage_primary != secondary.base_voltage_primary !=
              tertiary.base_voltage_primary
    end

    @testset "ids are non-nothing and distinct" begin
        @test !isnothing(tx.id)
        for c in circuits
            @test !isnothing(c.id)
            @test c.id != tx.id
        end
        @test length(Set(c.id for c in circuits)) == 3
    end

    @testset "magnetizing_shunt: g/b survive as ComplexNumber, zero case" begin
        @test tx.magnetizing_shunt.real == 0.0
        @test tx.magnetizing_shunt.imag == 0.0
        @test tx.shunt_location == "STAR"
    end
end

@testset "Transformer3W: g/b magnetizing_shunt, nonzero case" begin
    led = PSU.Ledger()
    rep = PSU.ConversionReport()
    ctx = PSU.TranslationContext(led, rep, 100.0)
    PSU.assign_id!(led, "uuid-3w-shunt")
    PSU.assign_id!(led, "uuid-star-shunt")
    PSU.assign_id!(led, "uuid-parc-shunt")
    PSU.assign_id!(led, "uuid-sarc-shunt")
    PSU.assign_id!(led, "uuid-tarc-shunt")

    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "Transformer3W"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-3w-shunt")),
        "name" => "shunt-test", "available" => true,
        "star_bus" => Dict("value" => "uuid-star-shunt"),
        "primary_star_arc" => Dict("value" => "uuid-parc-shunt"),
        "secondary_star_arc" => Dict("value" => "uuid-sarc-shunt"),
        "tertiary_star_arc" => Dict("value" => "uuid-tarc-shunt"),
        "r_primary" => 0.01, "x_primary" => 0.02,
        "r_secondary" => 0.03, "x_secondary" => 0.04,
        "r_tertiary" => 0.05, "x_tertiary" => 0.06,
        "r_12" => 0.07, "x_12" => 0.08,
        "r_23" => 0.09, "x_23" => 0.10,
        "r_13" => 0.11, "x_13" => 0.12,
        "base_power_12" => 100.0, "base_power_23" => 100.0, "base_power_13" => 100.0,
        "primary_turns_ratio" => 1.0, "secondary_turns_ratio" => 1.0,
        "tertiary_turns_ratio" => 1.0,
        "available_primary" => true, "available_secondary" => true,
        "available_tertiary" => true,
        "rating_primary" => 1.0, "rating_secondary" => 2.0, "rating_tertiary" => 3.0,
        "base_voltage_primary" => 110.0, "base_voltage_secondary" => 22.0,
        "base_voltage_tertiary" => 33.0,
        # The case the corpus cannot exercise: a nonzero magnetizing shunt.
        "g" => 0.0013, "b" => 0.021,
        "active_power_flow_primary" => 0.0, "reactive_power_flow_primary" => 0.0,
        "active_power_flow_secondary" => 0.0, "reactive_power_flow_secondary" => 0.0,
        "active_power_flow_tertiary" => 0.0, "reactive_power_flow_tertiary" => 0.0,
    )

    out = PSU.translate_component(raw, ctx)
    tx = only(filter(_is_three_winding, out))
    @test tx.magnetizing_shunt.real == 0.0013
    @test tx.magnetizing_shunt.imag == 0.021
    @test tx.shunt_location == "STAR"
    # g/b are consumed now; top-level available (no top-level rating in this fixture) is
    # still redundant with the per-circuit fields and stays a recorded drop.
    @test Set(keys(rep.unmapped_fields)) == Set([("Transformer3W", "available")])
end

@testset "Transformer3W: per-winding tap, available, alpha routing" begin
    led = PSU.Ledger()
    rep = PSU.ConversionReport()
    ctx = PSU.TranslationContext(led, rep, 100.0)
    PSU.assign_id!(led, "uuid-3w-route")
    PSU.assign_id!(led, "uuid-star-route")
    PSU.assign_id!(led, "uuid-parc-route")
    PSU.assign_id!(led, "uuid-sarc-route")
    PSU.assign_id!(led, "uuid-tarc-route")

    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "Transformer3W"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-3w-route")),
        "name" => "route-test", "available" => true,
        "star_bus" => Dict("value" => "uuid-star-route"),
        "primary_star_arc" => Dict("value" => "uuid-parc-route"),
        "secondary_star_arc" => Dict("value" => "uuid-sarc-route"),
        "tertiary_star_arc" => Dict("value" => "uuid-tarc-route"),
        "r_primary" => 0.01, "x_primary" => 0.02,
        "r_secondary" => 0.03, "x_secondary" => 0.04,
        "r_tertiary" => 0.05, "x_tertiary" => 0.06,
        "r_12" => 0.07, "x_12" => 0.08,
        "r_23" => 0.09, "x_23" => 0.10,
        "r_13" => 0.11, "x_13" => 0.12,
        "base_power_12" => 100.0, "base_power_23" => 100.0, "base_power_13" => 100.0,
        "primary_turns_ratio" => 1.01, "secondary_turns_ratio" => 1.02,
        "tertiary_turns_ratio" => 1.03,
        "available_primary" => true, "available_secondary" => false,
        "available_tertiary" => true,
        "primary_group_number" => "GROUP_1",
        "secondary_group_number" => "GROUP_0",
        "tertiary_group_number" => "GROUP_11",
        "rating_primary" => 1.0, "rating_secondary" => 2.0, "rating_tertiary" => 3.0,
        "base_voltage_primary" => 110.0, "base_voltage_secondary" => 22.0,
        "base_voltage_tertiary" => 33.0,
        "g" => 0.0, "b" => 0.0,
        "active_power_flow_primary" => 0.0, "reactive_power_flow_primary" => 0.0,
        "active_power_flow_secondary" => 0.0, "reactive_power_flow_secondary" => 0.0,
        "active_power_flow_tertiary" => 0.0, "reactive_power_flow_tertiary" => 0.0,
    )

    out = PSU.translate_component(raw, ctx)
    circuits = filter(_is_circuit, out)
    primary = only(c for c in circuits if c.tap == 1.01)
    secondary = only(c for c in circuits if c.tap == 1.02)
    tertiary = only(c for c in circuits if c.tap == 1.03)

    @test primary.available
    @test !secondary.available
    @test tertiary.available

    # This is the case the real corpus cannot exercise: a non-GROUP_0 winding group.
    @test primary.alpha ≈ -pi / 6
    @test secondary.alpha == 0.0
    @test tertiary.alpha ≈ pi / 6
end

@testset "Transformer3W: top-level available=false errors loudly" begin
    # available_$suffix's own PSY5 default is true, so a dropped top-level
    # available=false would otherwise be silently replaced by three available circuits.
    led = PSU.Ledger()
    rep = PSU.ConversionReport()
    ctx = PSU.TranslationContext(led, rep, 100.0)

    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "Transformer3W"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-3w-unavailable")),
        "name" => "unavailable-3w",
        "available" => false,
    )

    @test_throws PSU.Psy5FormatError PSU.translate(Val(:Transformer3W), raw, ctx)
end

@testset "Transformer3W: non-zero top-level rating with a zero per-winding rating errors loudly" begin
    # rating_$suffix's own PSY5 default is 0.0, so a real top-level rating paired with a
    # still-default per-winding rating would otherwise be silently replaced by zero.
    led = PSU.Ledger()
    rep = PSU.ConversionReport()
    ctx = PSU.TranslationContext(led, rep, 100.0)

    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "Transformer3W"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-3w-badrating")),
        "name" => "badrating-3w",
        "available" => true,
        "rating" => 50.0,
        "rating_primary" => 1.0e6, "rating_secondary" => 1.0e6, "rating_tertiary" =>
            0.0,
    )

    @test_throws PSU.Psy5FormatError PSU.translate(Val(:Transformer3W), raw, ctx)
end

@testset "Transformer3W: the corpus's safe corner does not error" begin
    # The real corpus's one instance: top-level rating at its own PSY5 default (0.0),
    # every per-winding rating genuinely populated. Not an error case.
    raw = Dict{String, Any}(
        "available" => true,
        "rating" => 0.0,
        "rating_primary" => 1.0e6, "rating_secondary" => 1.0e6,
        "rating_tertiary" => 1.0e6,
    )
    @test PSU._check_transformer3w_top_level!(raw) === nothing
end

@testset "real Transformer3W from case10_radial_series_reductions" begin
    dir = joinpath(@__DIR__, "..", "data", "PSITestSystems")
    path = joinpath(dir, "case10_radial_series_reductions")
    if require_corpus_file(path)
        case = PSU.read_psy5(path)
        led = PSU.Ledger()
        rep = PSU.ConversionReport()
        ctx = PSU.TranslationContext(led, rep, PSU.system_base_power(case))

        tx_raw = only(
            c for c in PSU.components(case) if PSU.component_type(c) == "Transformer3W"
        )
        PSU.assign_id!(led, PSU.component_uuid(tx_raw))
        PSU.assign_id!(led, tx_raw["star_bus"]["value"])
        PSU.assign_id!(led, tx_raw["primary_star_arc"]["value"])
        PSU.assign_id!(led, tx_raw["secondary_star_arc"]["value"])
        PSU.assign_id!(led, tx_raw["tertiary_star_arc"]["value"])

        out = PSU.translate_component(tx_raw, ctx)
        @test length(out) == 4

        tx = only(filter(_is_three_winding, out))
        circuits = filter(_is_circuit, out)
        @test length(circuits) == 3

        ids = Set(c.id for c in circuits)
        push!(ids, tx.id)
        @test length(ids) == 4

        # THE TRAP, against the real file: PSY5 r_13/x_13/base_power_13 land on r_31/x_31/base_power_31.
        @test tx.r_31 == tx_raw["r_13"]
        @test tx.x_31 == tx_raw["x_13"]
        @test tx.base_power_31 == tx_raw["base_power_13"]

        @test tx.magnetizing_shunt.real == tx_raw["g"]
        @test tx.magnetizing_shunt.imag == tx_raw["b"]
        # Pinned even though g == b == 0.0 here: the corpus can't catch a wrong location.
        @test tx.shunt_location == "STAR"

        # PSY5's top-level `available`/`rating` are redundant with the per-circuit
        # available_$suffix/rating_$suffix fields (PSY6 has neither on the transformer
        # itself, only on TransformerCircuit) and are correctly dropped-and-recorded. `g`/`b`
        # now feed magnetizing_shunt, so they no longer appear here.
        @test Set(keys(rep.unmapped_fields)) ==
              Set([("Transformer3W", "available"), ("Transformer3W", "rating")])
        for count in values(rep.unmapped_fields)
            @test count == 1
        end
    end
end

@testset "real transformer from c_sys14" begin
    dir = joinpath(@__DIR__, "..", "data", "PSITestSystems")
    path = joinpath(dir, "c_sys14")
    if require_corpus_file(path)
        case = PSU.read_psy5(path)
        led = PSU.Ledger()
        rep = PSU.ConversionReport()
        ctx = PSU.TranslationContext(led, rep, PSU.system_base_power(case))

        tap_raw = first(
            c for c in PSU.components(case) if PSU.component_type(c) == "TapTransformer"
        )
        PSU.assign_id!(led, PSU.component_uuid(tap_raw))
        PSU.assign_id!(led, tap_raw["arc"]["value"])

        out = PSU.translate_component(tap_raw, ctx)
        circuit = only(filter(_is_circuit, out))
        transformer = only(filter(_is_two_winding, out))

        @test circuit.alpha == 0.0                       # UNDEFINED group in this corpus
        @test circuit.tap == tap_raw["tap"]
        @test transformer.magnetizing_shunt.real == tap_raw["primary_shunt"]["real"]
        @test transformer.magnetizing_shunt.imag == tap_raw["primary_shunt"]["imag"]
        @test rep.unmapped_fields[("TapTransformer", "tap_limits")] == 1
    end
end
