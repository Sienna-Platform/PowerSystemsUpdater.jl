using PowerOperationsOpenAPIModels: TwoTerminalLCCLine, TwoTerminalVSCLine

@testset "must_run → commitment_mode" begin
    POOM = PSU.POOM
    raw = Dict{String, Any}("__metadata__" => Dict("type" => "ThermalStandard"))
    derived = PSU._derive_commitment_mode(
        POOM.ThermalStandard,
        merge(raw, Dict("must_run" => true)),
    )
    @test derived["commitment_mode"] == "MUST_RUN"
    @test !haskey(derived, "must_run")
    # `false` is PSY6's default: consumed, nothing written.
    derived = PSU._derive_commitment_mode(
        POOM.ThermalStandard,
        merge(raw, Dict("must_run" => false)),
    )
    @test !haskey(derived, "commitment_mode") && !haskey(derived, "must_run")
    # A type with no commitment_mode keeps the field, to be reported and kept in ext.
    @test haskey(
        PSU._derive_commitment_mode(POOM.ACBus, merge(raw, Dict("must_run" => true))),
        "must_run",
    )
end

@testset "MarketBidCost.no_load_cost → minimum_energy_offer" begin
    ctx = PSU.TranslationContext(PSU.Ledger(), PSU.ConversionReport(), 100.0)
    raw = Dict{String, Any}(
        "base_power" => 100.0,
        "active_power_limits" => Dict("min" => 0.5, "max" => 1.0),
        "operation_cost" => Dict{String, Any}(
            "__metadata__" => Dict("type" => "MarketBidCost"),
            "no_load_cost" => 30.0,
        ),
    )
    cost = PSU._derive_minimum_energy_offer(raw, ctx)["operation_cost"]
    @test !haskey(cost, "no_load_cost")
    # $30/h at P_min = 0.5 pu × 100 MVA = 50 MW.
    @test cost["minimum_energy_offer"]["function_data"]["constant_term"] ≈ 0.6
    @test cost["minimum_energy_offer"]["function_data"]["proportional_term"] == 0.0
    # No positive P_min: left as is, for the copy to report and keep in ext.
    raw["active_power_limits"] = Dict("min" => 0.0, "max" => 1.0)
    @test haskey(
        PSU._derive_minimum_energy_offer(raw, ctx)["operation_cost"],
        "no_load_cost",
    )
end

@testset "LCC power_mode + transfer_setpoint → control_mode + setpoint" begin
    power = PSU._lcc_control(
        Dict{String, Any}("power_mode" => true, "transfer_setpoint" => 50.0),
    )
    @test power ==
          Dict{String, Any}("control_mode" => "POWER", "power_transfer_setpoint" => 50.0)
    current =
        PSU._lcc_control(
            Dict{String, Any}("power_mode" => false, "transfer_setpoint" => 800.0),
        )
    @test current ==
          Dict{String, Any}(
        "control_mode" => "CURRENT",
        "current_transfer_setpoint" => 800.0,
    )

    # Units: the MW setpoint is written per unit on the line's base.
    ctx = PSU.TranslationContext(PSU.Ledger(), PSU.ConversionReport(), 100.0)
    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "TwoTerminalLCCLine"),
        "power_transfer_setpoint" => 50.0,
        "current_transfer_setpoint" => 800.0,
    )
    kwargs = PSU.build_kwargs(
        TwoTerminalLCCLine, raw, ctx.ledger, ctx.report;
        units = PSU.component_units(raw, ctx),
    )
    @test kwargs[:power_transfer_setpoint] ≈ 0.5
    @test kwargs[:current_transfer_setpoint] == 800.0
    @test isempty(ctx.report.unverified_units)
end

@testset "VSC setpoints → one field per controlled quantity" begin
    raw = Dict{String, Any}(
        "dc_control_from" => "DC_VOLTAGE", "dc_setpoint_from" => 1.02,
        "dc_control_to" => "DC_POWER", "dc_setpoint_to" => -0.5,
        "ac_control_from" => "AC_VOLTAGE", "ac_setpoint_from" => 1.01,
        "ac_control_to" => "AC_REACTIVE_POWER", "ac_setpoint_to" => 0.95,
    )
    derived = PSU._vsc_setpoints(raw)
    @test derived["dc_voltage_setpoint_from"] == 1.02
    @test derived["dc_power_setpoint_to"] == -0.5
    @test derived["ac_voltage_setpoint_from"] == 1.01
    @test derived["power_factor_setpoint_to"] == 0.95
    @test !any(
        haskey(derived, k) for
        k in ("dc_setpoint_from", "dc_setpoint_to", "ac_setpoint_from", "ac_setpoint_to")
    )
    # PSY5's remote bus 0 ("its own terminal bus") is PSY6's unset remote bus.
    @test !haskey(
        PSU._vsc_setpoints(Dict{String, Any}("remote_bus_control_from" => 0)),
        "remote_bus_control_from",
    )
    @test PSU._vsc_setpoints(Dict{String, Any}("remote_bus_control_to" => 7))["remote_bus_control_to"] ==
          7

    # Units: DC voltage on `rated_dc_voltage`, AC voltage on each converter's own bus.
    index = PSU.BusIndex(
        Dict("uuid-b1" => 230.0, "uuid-b2" => 138.0),
        Dict("uuid-arc" => ("uuid-b1", "uuid-b2")),
    )
    led = PSU.Ledger()
    PSU.assign_id!(led, "uuid-arc")
    ctx = PSU.TranslationContext(led, PSU.ConversionReport(), 100.0, index)
    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "TwoTerminalVSCLine"),
        "arc" => Dict("value" => "uuid-arc"),
        "rated_dc_voltage" => 500.0,
        "dc_voltage_setpoint_from" => 1.02,
        "dc_power_setpoint_to" => -0.5,
        "ac_voltage_setpoint_from" => 1.01,
        "ac_voltage_setpoint_to" => 0.99,
    )
    kwargs = PSU.build_kwargs(
        TwoTerminalVSCLine, raw, ctx.ledger, ctx.report;
        units = PSU.component_units(raw, ctx),
    )
    @test kwargs[:dc_voltage_setpoint_from] ≈ 510.0
    @test kwargs[:dc_power_setpoint_to] ≈ -0.5        # pu on the system base, unchanged
    @test kwargs[:ac_voltage_setpoint_from] ≈ 1.01 * 230.0
    @test kwargs[:ac_voltage_setpoint_to] ≈ 0.99 * 138.0
    @test isempty(ctx.report.unverified_units)

    # The AC bus base the setpoint was converted on is recorded as each side's rated voltage.
    rated = PSU._vsc_rated_ac_voltages(raw, ctx)
    @test rated["rated_ac_voltage_from"] == 230.0
    @test rated["rated_ac_voltage_to"] == 138.0
end

@testset "ImpedanceCorrectionData curve → per-mode field" begin
    curve = Dict{String, Any}(
        "__metadata__" => Dict("type" => "PiecewiseLinearData"),
        "points" => [
            Dict{String, Any}("x" => -60.0, "y" => 1.5),
            Dict{String, Any}("x" => 30.0, "y" => 1.1),
        ],
    )
    tap = PSU._impedance_correction_curve(
        Dict{String, Any}(
            "impedance_correction_curve" => curve,
            "transformer_control_mode" => "TAP_RATIO",
        ),
    )
    @test tap["tap_ratio_correction_curve"] == curve
    @test !haskey(tap, "impedance_correction_curve")
    phase = PSU._impedance_correction_curve(
        Dict{String, Any}(
            "impedance_correction_curve" => curve,
            "transformer_control_mode" => "PHASE_SHIFT_ANGLE",
        ),
    )
    points = phase["phase_angle_correction_curve"]["points"]
    @test [p["x"] for p in points] ≈ [-pi / 3, pi / 6]   # degrees → radians
    @test [p["y"] for p in points] == [1.5, 1.1]
end
