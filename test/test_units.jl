using PowerOperationsOpenAPIModels: FixedAdmittance, HydroReservoir, TwoTerminalLCCLine

@testset "psy5_storage: generated table, hand table, wildcard, unknown" begin
    # Generated from PSY5's descriptors (`needs_conversion`).
    @test PSU.psy5_storage("ThermalStandard", "active_power") isa PSU.DeviceBasePU
    # Hand-kept: PSY5 never annotated these.
    @test PSU.psy5_storage("VariableReserve", "requirement") isa PSU.SystemBasePU
    @test PSU.psy5_storage("HydroReservoir", "initial_level") isa PSU.RelativeTo
    @test PSU.psy5_storage("HydroReservoir", "inflow") isa PSU.PerHour
    # Bases are physical, by name or wildcard.
    @test PSU.psy5_storage("ThermalStandard", "base_power") isa PSU.Natural
    @test PSU.psy5_storage("TransformerCircuit", "base_voltage_primary") isa PSU.Natural
    @test PSU.psy5_storage("SomeType", "some_field") isa PSU.UnknownStorage
    @test PSU.psy5_storage("TwoTerminalLCCLine", "rectifier_xc") isa
          PSU.SystemBasePUOnVoltage
    # The generated table is complete: PSY5 5.x marks 240 fields `needs_conversion`.
    @test length(PSU.PSY5_DEVICE_BASE_FIELDS) == 240
end

@testset "target_unit: from the schema's unit annotations" begin
    POOM = PSU.POOM
    # A per-unit basis is chosen whenever there is one.
    @test PSU.target_unit(POOM.ThermalStandard, :rating, Dict{String, Any}()) ==
          ("pu", :power_units => "COMPONENT_BASE")
    @test PSU.target_unit(POOM.Line, :r, Dict{String, Any}()) ==
          ("pu", :parameter_units => "COMPONENT_BASE")
    # A fixed unit has no basis to write.
    @test PSU.target_unit(POOM.OnlineReserve, :requirement, Dict{String, Any}()) ==
          ("MW", nothing)
    # No per-unit basis: the power one.
    @test PSU.target_unit(FixedAdmittance, :y, Dict{String, Any}()) ==
          ("MVAr", :admittance_units => "COMPONENT_MVAR")
    # A data discriminator is read from the record.
    @test PSU.target_unit(
        HydroReservoir,
        :initial_level,
        Dict{String, Any}("level_data_type" => "ENERGY"),
    ) == ("MWh", nothing)
    @test PSU.target_unit(
        HydroReservoir,
        :inflow,
        Dict{String, Any}("level_data_type" => "USABLE_VOLUME"),
    ) == ("m3/s", nothing)
    # No declared unit at all.
    @test PSU.target_unit(POOM.ThermalStandard, :name, Dict{String, Any}()) ==
          (nothing, nothing)
end

function _units_ctx(; buses = Dict("uuid-b1" => 230.0, "uuid-b2" => 230.0))
    led = PSU.Ledger()
    rep = PSU.ConversionReport()
    index = PSU.BusIndex(
        Dict{String, Float64}(buses),
        Dict{String, Tuple{String, String}}("uuid-arc" => ("uuid-b1", "uuid-b2")),
    )
    for uuid in ("uuid-b1", "uuid-b2", "uuid-arc", "uuid-c")
        PSU.assign_id!(led, uuid)
    end
    return PSU.TranslationContext(led, rep, 100.0, index), led, rep
end

@testset "FixedAdmittance: system-base pu to MVAr" begin
    ctx, _, rep = _units_ctx()
    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "FixedAdmittance"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-c")),
        "name" => "shunt", "available" => true,
        "bus" => Dict("value" => "uuid-b1"),
        "Y" => Dict("real" => 0.0, "imag" => 0.32),
    )
    shunt = only(PSU.translate_component(raw, ctx))
    @test shunt.y.imag ≈ 32.0
    @test string(shunt.admittance_units) == "COMPONENT_MVAR"
    @test isempty(rep.unverified_units)
end

@testset "HydroReservoir: fraction levels to absolute, flows per hour to per second" begin
    ctx, _, rep = _units_ctx()
    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "HydroReservoir"),
        "level_data_type" => "USABLE_VOLUME",
        "storage_level_limits" => Dict("min" => 0.0, "max" => 5000.0),
        "initial_level" => 0.5,
        "level_targets" => 1.0,
        "inflow" => 3600.0,
        "outflow" => 7200.0,
    )
    kwargs = PSU.build_kwargs(
        HydroReservoir, raw, ctx.ledger, ctx.report;
        units = PSU.component_units(raw, ctx),
    )
    @test kwargs[:initial_level] == 2500.0
    @test kwargs[:level_targets] == 5000.0
    @test kwargs[:storage_level_limits].max == 5000.0   # already absolute
    @test kwargs[:inflow] ≈ 1.0                          # m3/h → m3/s
    @test kwargs[:outflow] ≈ 2.0
    @test isempty(rep.unverified_units)

    # In ENERGY mode flows are MW either way.
    raw["level_data_type"] = "ENERGY"
    kwargs = PSU.build_kwargs(
        HydroReservoir, raw, ctx.ledger, ctx.report;
        units = PSU.component_units(raw, ctx),
    )
    @test kwargs[:inflow] == 3600.0
end

@testset "LCC impedances: system-base pu to ohm on the circuit's own voltage" begin
    # The PSS/E case's values: PSY5's parser divides RDC by VSCHD^2 / baseMVA and each
    # converter's RC/XC/XCAP by its EBAS^2 / baseMVA, whatever the buses' base voltages.
    function _lcc(ctx; extra...)
        raw = Dict{String, Any}(
            "__metadata__" => Dict("type" => "TwoTerminalLCCLine"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-c")),
            "arc" => Dict("value" => "uuid-arc"),
            "r" => 2000.0, "scheduled_dc_voltage" => 1.0,
            "rectifier_rc" => 0.02, "rectifier_xc" => 0.0003364839319470699,
            "rectifier_capacitor_reactance" => 0.01, "rectifier_base_voltage" => 230.0,
            "inverter_xc" => 0.08, "inverter_base_voltage" => 69.0,
            "compounding_resistance" => 3.0,
        )
        merge!(raw, Dict{String, Any}(String(k) => v for (k, v) in extra))
        units = PSU.component_units(raw, ctx)
        return PSU.build_kwargs(
            TwoTerminalLCCLine,
            raw,
            ctx.ledger,
            ctx.report;
            units = units,
        )
    end
    # Bus bases deliberately different from every circuit base.
    ctx, _, rep = _units_ctx(; buses = Dict("uuid-b1" => 138.0, "uuid-b2" => 345.0))
    kwargs = _lcc(ctx)
    @test kwargs[:r] ≈ 2000.0 * 1.0^2 / 100.0             # 20 ohm on VSCHD = 1 kV
    @test kwargs[:rectifier_rc] ≈ 0.02 * 230.0^2 / 100.0
    @test kwargs[:rectifier_xc] ≈ 0.178                    # PSS/E's XCR
    @test kwargs[:rectifier_capacitor_reactance] ≈ 0.01 * 230.0^2 / 100.0
    @test kwargs[:inverter_xc] ≈ 0.08 * 69.0^2 / 100.0
    @test kwargs[:compounding_resistance] == 3.0   # already ohm
    @test kwargs[:scheduled_dc_voltage] == 1.0     # already kV
    @test isempty(rep.unverified_units)
    @test isempty(rep.dropped_invalid_values)

    # A non-physical converter base: a required impedance is written as stored and reported.
    ctx, _, rep = _units_ctx()
    kwargs = _lcc(ctx; inverter_base_voltage = 0.0)
    @test kwargs[:inverter_xc] == 0.08
    @test rep.dropped_invalid_values[("TwoTerminalLCCLine", "inverter_xc")] == 1
end

@testset "VSC with no DC voltage base: values on it are reported" begin
    # `c_sys14_hvdc_vsc`: rated_dc_voltage 0, so a DC voltage setpoint has no value in kV.
    ctx, led, rep = _units_ctx()
    led.owner = "uuid-c"
    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "TwoTerminalVSCLine"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-c")),
        "arc" => Dict("value" => "uuid-arc"),
        "rated_dc_voltage" => 0.0,
        "dc_voltage_setpoint_from" => 0.0,
        "voltage_limits_from" => Dict("min" => 0.9, "max" => 1.1),
    )
    kwargs = PSU.build_kwargs(
        PSU.POOM.TwoTerminalVSCLine, raw, led, rep;
        units = PSU.component_units(raw, ctx),
    )
    for field in ("rated_dc_voltage", "voltage_limits_from")
        @test !haskey(kwargs, Symbol(field))
        @test rep.dropped_invalid_values[("TwoTerminalVSCLine", field)] == 1
        @test haskey(PSU.unmapped_values(led, "uuid-c"), field)
    end
    # The setpoint its control mode selects is required by the schema: written as stored, and
    # still reported.
    @test kwargs[:dc_voltage_setpoint_from] == 0.0
    @test rep.dropped_invalid_values[("TwoTerminalVSCLine", "dc_voltage_setpoint_from")] ==
          1
    @test isempty(rep.unverified_units)
end

@testset "unverified units: reported, never silently copied" begin
    POOM = PSU.POOM
    ctx, led, rep = _units_ctx()
    led.owner = "uuid-c"
    # Optional field, PSY5 storage unknown, physical PSY6 unit: left unset, kept in ext.
    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "MysteryReserve"),
        "requirement" => 0.4,
    )
    kwargs = PSU.build_kwargs(
        POOM.OnlineReserve, raw, led, rep; units = PSU.component_units(raw, ctx),
    )
    @test !haskey(kwargs, :requirement)
    @test rep.unverified_units[("MysteryReserve", "requirement")] == 1
    @test PSU.unmapped_values(led, "uuid-c")["requirement"] == 0.4

    # Required field: written as stored, still reported.
    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "MysteryGroup"),
        "requirement" => 0.4,
    )
    kwargs = PSU.build_kwargs(
        POOM.GroupReserve, raw, led, rep; units = PSU.component_units(raw, ctx),
    )
    @test kwargs[:requirement] == 0.4
    @test rep.unverified_units[("MysteryGroup", "requirement")] == 1
end

@testset "non-physical transformer base voltages are left unset and reported" begin
    @test PSU._non_physical_base("base_voltage_primary", 0.0)
    @test PSU._non_physical_base("base_voltage_secondary", -1.0)
    @test !PSU._non_physical_base("base_voltage_primary", 138.0)
    # A bus's base voltage is written as stored (PSY6's Line check needs one).
    @test !PSU._non_physical_base("base_voltage", 0.0)
    @test !PSU._non_physical_base("rating", 0.0)

    ctx, led, rep = _units_ctx()
    led.owner = "uuid-c"
    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "TapTransformer"),
        "base_voltage_primary" => 0.0,
        "base_voltage_secondary" => 69.0,
    )
    kwargs = PSU.build_kwargs(
        PSU.POOM.TransformerCircuit, raw, led, rep;
        units = PSU.component_units(raw, ctx),
    )
    @test !haskey(kwargs, :base_voltage_primary)
    @test kwargs[:base_voltage_secondary] == 69.0
    @test rep.dropped_invalid_values[("TapTransformer", "base_voltage_primary")] == 1
    @test PSU.unmapped_values(led, "uuid-c")["base_voltage_primary"] == 0.0
    @test occursin("INVALID VALUES DROPPED", sprint(show, MIME("text/plain"), rep))

    # A zero bus base is no voltage base for unit conversion either.
    zero_bus = Dict{String, Any}(
        "__metadata__" => Dict("type" => "ACBus"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-z")),
        "base_voltage" => 0.0,
    )
    @test isempty(PSU.BusIndex([zero_bus]).base_voltage)
end
