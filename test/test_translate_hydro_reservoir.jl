@testset "translate HydroReservoir: head_to_volume_factor unwrap" begin
    dir = joinpath(@__DIR__, "..", "data", "PSITestSystems")
    path = joinpath(dir, "c_sys5_hy_uc")
    if require_corpus_file(path)
        case = PSU.read_psy5(path)
        led = PSU.Ledger()
        rep = PSU.ConversionReport()
        ctx = PSU.TranslationContext(led, rep, PSU.system_base_power(case))

        raw = only(
            c for c in PSU.components(case) if PSU.component_type(c) == "HydroReservoir"
        )
        PSU.assign_id!(led, PSU.component_uuid(raw))
        for reference in raw["downstream_turbines"]
            PSU.assign_id!(led, reference["value"])
        end

        # PSY5's real shape: an InputOutputCurve wrapping a LinearFunctionData, one level
        # deeper than PSY6's schema wants.
        original = raw["head_to_volume_factor"]
        @test original["__metadata__"]["type"] == "InputOutputCurve"
        @test original["function_data"]["__metadata__"]["type"] == "LinearFunctionData"
        @test isnothing(original["input_at_zero"])

        models = PSU.translate(Val(:HydroReservoir), raw, ctx)
        reservoir = only(models)

        # PSY6's shape: a bare FunctionData, discriminated at the top level. Under the
        # OpenAPI 1.1 generator, `build_kwargs` decodes this into the real FunctionData/
        # LinearFunctionData structs (not a raw Dict), so the field is reached via `.value`
        # rather than string indexing; a `LinearFunctionData` instance structurally cannot
        # carry `curve_type`/`input_at_zero` (those belong to the unwrapped InputOutputCurve
        # level), which is what the old haskey checks were proving.
        translated = reservoir.head_to_volume_factor
        @test typeof(translated) === PSU.ICOM.FunctionData
        @test typeof(translated.value) === PSU.ICOM.LinearFunctionData
        @test translated.value.function_type == "LINEAR"
        @test translated.value.constant_term == original["function_data"]["constant_term"]
        @test translated.value.proportional_term ==
              original["function_data"]["proportional_term"]

        @test isempty(rep.unmapped_fields)
    end
end

@testset "translate HydroReservoir: non-null input_at_zero is recorded, not dropped" begin
    led = PSU.Ledger()
    rep = PSU.ConversionReport()
    ctx = PSU.TranslationContext(led, rep, 100.0)

    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "HydroReservoir"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-reservoir")),
        "name" => "res",
        "available" => true,
        "storage_level_limits" => Dict("min" => 0.0, "max" => 1.0),
        "initial_level" => 0.5,
        "inflow" => 1.0,
        "outflow" => 1.0,
        "intake_elevation" => 0.0,
        "head_to_volume_factor" => Dict{String, Any}(
            "__metadata__" => Dict("type" => "InputOutputCurve"),
            "input_at_zero" => 3.5,
            "function_data" => Dict{String, Any}(
                "__metadata__" => Dict("type" => "LinearFunctionData"),
                "constant_term" => 0.0,
                "proportional_term" => 1.0,
            ),
        ),
        "operation_cost" => Dict{String, Any}(
            "__metadata__" => Dict("type" => "HydroReservoirCost"),
            "spillage_cost" => 0.0,
            "level_shortage_cost" => 0.0,
            "level_surplus_cost" => 0.0,
        ),
    )
    PSU.assign_id!(led, "uuid-reservoir")

    PSU.translate(Val(:HydroReservoir), raw, ctx)

    @test rep.unmapped_fields[("HydroReservoir", "head_to_volume_factor.input_at_zero")] ==
          1
end
