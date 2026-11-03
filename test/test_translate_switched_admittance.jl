using PowerOperationsOpenAPIModels: SwitchedAdmittance

"""A PSY5 `SwitchedAdmittance` as PSY5's PSS/E parser writes it, with `overrides` applied."""
function _switched_admittance_raw(; overrides...)
    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "SwitchedAdmittance"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-swsh")),
        "name" => "swsh", "available" => true,
        "bus" => Dict("value" => "uuid-swsh-bus"),
        "Y" => Dict("real" => 0.0, "imag" => 0.5),
        "initial_status" => [0, 0],
        "number_of_steps" => [2, 1],
        "Y_increase" =>
            [Dict("real" => 0.0, "imag" => 0.1), Dict("real" => 0.0, "imag" => 0.2)],
        "admittance_limits" => Dict("min" => 0.95, "max" => 1.05),
        "control_mode" => "CONTINUOUS_VOLTAGE",
        "regulated_bus_number" => 0,
        "dynamic_injector" => nothing,
        "services" => Any[],
        "ext" => Dict{String, Any}(),
    )
    for (key, value) in overrides
        raw[String(key)] = value
    end
    return raw
end

function _translate_switched_admittance(raw)
    led = PSU.Ledger()
    rep = PSU.ConversionReport()
    ctx = PSU.TranslationContext(led, rep, 100.0)
    PSU.assign_id!(led, "uuid-swsh")
    PSU.assign_id!(led, "uuid-swsh-bus")
    shunt = only(PSU.translate_component(raw, ctx))
    return shunt, rep, led
end

@testset "SwitchedAdmittance: PowerFlowFileParser mapping" begin
    @test PSU.has_translator("SwitchedAdmittance")
    shunt, rep, led = _translate_switched_admittance(_switched_admittance_raw())
    @test shunt isa SwitchedAdmittance
    # BINIT and the block increments: system-base per unit in PSY5, MVAr in PSY6.
    @test shunt.solved_admittance ≈ 50.0
    @test [y.imag for y in shunt.y_increase] ≈ [10.0, 20.0]
    @test string(shunt.admittance_units.value) == "COMPONENT_MVAR"
    @test shunt.number_engaged == [0, 0]
    @test shunt.number_of_steps == [2, 1]
    @test (shunt.voltage_limits.min, shunt.voltage_limits.max) == (0.95, 1.05)
    @test shunt.reactive_power_range_limits isa PSU.ICOM.Absent
    @test isempty(rep.unmapped_fields)
    @test isempty(rep.approximate_mappings)
end

@testset "SwitchedAdmittance: the band follows the control mode" begin
    shunt, _, _ = _translate_switched_admittance(
        _switched_admittance_raw(; control_mode = "DISCRETE_REACTIVE_PLANT"),
    )
    @test shunt.voltage_limits isa PSU.ICOM.Absent
    @test (shunt.reactive_power_range_limits.min, shunt.reactive_power_range_limits.max) ==
          (0.95, 1.05)

    # FIXED uses no band: it is kept in ext.
    _, rep, led = _translate_switched_admittance(
        _switched_admittance_raw(; control_mode = "FIXED"),
    )
    @test rep.unmapped_fields[("SwitchedAdmittance", "admittance_limits")] == 1
    @test haskey(PSU.unmapped_values(led, "uuid-swsh"), "admittance_limits")
end

@testset "SwitchedAdmittance: Y = 0 leaves solved_admittance unset" begin
    # PSY6 then sums the engaged blocks, as PSY5 does.
    shunt, rep, _ = _translate_switched_admittance(
        _switched_admittance_raw(;
            Y = Dict("real" => 0.0, "imag" => 0.0),
            initial_status = [0, 1],
        ),
    )
    @test shunt.solved_admittance isa PSU.ICOM.Absent
    @test shunt.number_engaged == [0, 1]
    @test isempty(rep.approximate_mappings)
end

@testset "SwitchedAdmittance: approximations are reported" begin
    # Y != 0 with a block in service: PSY5 adds the block to Y, PSY6 uses Y alone.
    _, rep, _ =
        @test_logs (:warn, r"effective admittance differs") match_mode = :any _translate_switched_admittance(
            _switched_admittance_raw(; initial_status = [0, 1]),
        )
    @test rep.approximate_mappings[("SwitchedAdmittance", "solved_admittance")] == 1
    @test !haskey(rep.approximate_mappings, ("SwitchedAdmittance", "number_engaged"))

    # An in-service block with several steps: the flag is not a step count.
    _, rep, _ =
        @test_logs (:warn, r"step count") match_mode = :any _translate_switched_admittance(
            _switched_admittance_raw(;
                Y = Dict("real" => 0.0, "imag" => 0.0),
                initial_status = [1, 0],
            ),
        )
    @test rep.approximate_mappings[("SwitchedAdmittance", "number_engaged")] == 1
    @test !haskey(rep.approximate_mappings, ("SwitchedAdmittance", "solved_admittance"))
end

@testset "SwitchedAdmittance: a conductance is kept in ext" begin
    _, rep, led =
        @test_logs (:warn, r"conductance") match_mode = :any _translate_switched_admittance(
            _switched_admittance_raw(; Y = Dict("real" => 0.01, "imag" => 0.5)),
        )
    @test rep.unmapped_fields[("SwitchedAdmittance", "Y")] == 1
    @test PSU.unmapped_values(led, "uuid-swsh")["Y"]["real"] == 0.01
end
