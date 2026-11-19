@testset "psy5 multipliers" begin
    function owner(type; fields...)
        raw = Dict{String, Any}("__metadata__" => Dict{String, Any}("type" => type))
        for (k, v) in fields
            raw[string(k)] = v
        end
        return raw
    end
    factor(m, raw, base = 100.0) = PSU.scale_factor(m, raw, base)
    active = PSU.MaxActivePower()
    reactive = PSU.MaxReactivePower()

    @testset "max active power rules" begin
        for type in ("RenewableDispatch", "RenewableNonDispatch")
            raw = owner(type; rating = 2.0, power_factor = 0.5)
            @test factor(active, raw) == 1.0
        end
        load = owner(
            "StandardLoad";
            max_constant_active_power = 1.0,
            max_impedance_active_power = 2.0,
            max_current_active_power = 4.0,
        )
        @test factor(active, load) == 7.0
        @test factor(
            active,
            owner("InterruptibleStandardLoad"; max_constant_active_power = 1.0,
                max_impedance_active_power = 2.0, max_current_active_power = 4.0),
        ) == 7.0
        @test factor(active, owner("PowerLoad"; max_active_power = 3.33)) == 3.33
        @test factor(
            active,
            owner(
                "ThermalStandard";
                active_power_limits = Dict("min" => 1.0, "max" => 8.5),
            ),
        ) == 8.5
        @test factor(
            active,
            owner("PowerLoad"; max_active_power = nothing,
                active_power_limits = Dict("min" => 0.0, "max" => 2.0)),
        ) == 2.0
    end

    @testset "max reactive power rules" begin
        nondispatch = owner("RenewableNonDispatch"; rating = 2.0, power_factor = 0.6)
        @test factor(reactive, nondispatch) ≈ 2.0 * 0.8
        limits = Dict("min" => -1.0, "max" => 0.7)
        @test factor(
            reactive,
            owner("RenewableDispatch"; rating = 2.0, power_factor = 0.6,
                reactive_power_limits = limits),
        ) == 0.7
        @test factor(
            reactive,
            owner("RenewableDispatch"; rating = 2.0, power_factor = 0.6,
                reactive_power_limits = nothing),
        ) ≈ 1.6
        @test factor(reactive, owner("PowerLoad"; max_reactive_power = 0.25)) == 0.25
        @test factor(reactive, owner("ThermalStandard"; reactive_power_limits = limits)) ==
              0.7
    end

    @testset "system base rules" begin
        @test factor(
            PSU.Requirement(),
            owner("VariableReserve"; requirement = 0.05),
            200.0,
        ) ==
              10.0
        @test factor(
            PSU.PeakActivePower(),
            owner("Area"; peak_active_power = 0.5),
            200.0,
        ) ==
              100.0
    end

    @testset "no factor" begin
        cases = [
            (active, owner("FixedAdmittance")),
            (active, owner("HybridSystem")),
            (reactive, owner("ThermalStandard"; reactive_power_limits = nothing)),
            (reactive, owner("PowerLoad")),
            (active, owner("PowerLoad"; max_active_power = NaN)),
            (active, owner("RenewableDispatch"; rating = NaN, power_factor = 1.0)),
            (PSU.Requirement(), owner("VariableReserve"; requirement = Inf)),
        ]
        for (m, raw) in cases
            @test !PSU.has_scale_factor(m, raw, 100.0)
            @test_throws PSU.Psy5FormatError factor(m, raw)
        end
    end

    @testset "reservoir multiplier" begin
        m = PSU.ReservoirMultiplier()
        raw = owner("HydroReservoir")
        @test PSU.has_scale_factor(m, raw, 100.0)
        @test factor(m, raw) == 1.0
    end

    @testset "name lookup" begin
        @test sort(collect(keys(PSU.PSY5_MULTIPLIERS))) == [
            "get_inflow", "get_max_active_power", "get_max_reactive_power",
            "get_peak_active_power", "get_requirement", "get_storage_capacity",
            "get_storage_target",
        ]
        @test PSU.psy5_multiplier("get_requirement") === PSU.Requirement()
        @test PSU.psy5_multiplier("get_inflow") === PSU.ReservoirMultiplier()
        @test_throws PSU.Psy5FormatError PSU.psy5_multiplier("get_bogus")
        @test_throws r"get_bogus" PSU.psy5_multiplier("get_bogus")
    end

    @testset "store_labels" begin
        @test PSU.store_labels(active) ==
              (units = nothing, quantity_kind = "ActivePower", per_unit_of = "base_power")
        @test PSU.store_labels(reactive) ==
              (units = nothing, quantity_kind = "ReactivePower", per_unit_of = "base_power")
        mw = (units = "MW", quantity_kind = "ActivePower", per_unit_of = nothing)
        @test PSU.store_labels(PSU.Requirement()) == mw
        @test PSU.store_labels(PSU.PeakActivePower()) == mw
    end
end
