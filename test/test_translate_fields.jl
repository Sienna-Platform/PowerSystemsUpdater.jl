@testset "translate fields" begin
    using PowerOpenAPIModels: ACBus

    led = PSU.Ledger()
    bus_id = PSU.assign_id!(led, "uuid-bus")
    area_id = PSU.assign_id!(led, "uuid-area")
    rep = PSU.ConversionReport()

    raw = Dict{String, Any}(
        "__metadata__" => Dict("type" => "ACBus", "module" => "PowerSystems"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-bus")),
        "name" => "nodeA",
        "number" => 1,
        "available" => true,
        "bustype" => "REF",
        "angle" => 0.0,
        "magnitude" => 1.0,
        "base_voltage" => 230.0,
        "area" => Dict("value" => "uuid-area"),
        "load_zone" => nothing,
        "voltage_limits" => Dict("min" => 0.9, "max" => 1.05),
        "ext" => Dict{String, Any}(),
        "not_a_psy6_field" => 42,
    )

    kwargs = PSU.build_kwargs(ACBus, raw, led, rep; extra = Dict(:id => bus_id))

    @test kwargs[:id] == bus_id
    @test kwargs[:name] == "nodeA"
    @test kwargs[:number] == 1
    @test kwargs[:bustype] == "REF"
    @test kwargs[:area] == area_id          # reference resolved to Int
    @test kwargs[:base_voltage] == 230.0
    @test !haskey(kwargs, :not_a_psy6_field)
    @test rep.unmapped_fields[("ACBus", "not_a_psy6_field")] == 1

    bus = ACBus(; kwargs...)
    @test bus.name == "nodeA"
    @test bus.area == area_id

    # a reference to a skipped component is detected, not emitted dangling
    PSU.mark_skipped!(led, "uuid-gone", "no PSY6 schema for Widget")
    orphan = Dict{String, Any}(
        "__metadata__" => Dict("type" => "ACBus"),
        "internal" => Dict("uuid" => Dict("value" => "uuid-orphan")),
        "area" => Dict("value" => "uuid-gone"),
    )
    @test PSU.references_skipped(orphan, led)
    @test !PSU.references_skipped(raw, led)

    @testset "translate_value" begin
        # scalars pass through unchanged
        @test PSU.translate_value(42, led) == 42
        @test PSU.translate_value("plain-string", led) == "plain-string"
        @test PSU.translate_value(3.14, led) == 3.14
        @test PSU.translate_value(nothing, led) === nothing

        # a non-reference dict passes through unchanged
        plain_dict = Dict("min" => 0.9, "max" => 1.05)
        @test PSU.translate_value(plain_dict, led) == plain_dict

        # a vector of references resolves each element
        refs = [Dict("value" => "uuid-bus"), Dict("value" => "uuid-area")]
        @test PSU.translate_value(refs, led) == [bus_id, area_id]

        # a vector mixing references and scalars resolves only the references
        mixed = [Dict("value" => "uuid-bus"), 7, "tag"]
        @test PSU.translate_value(mixed, led) == [bus_id, 7, "tag"]
    end

    @testset "references_skipped negative and vector paths" begin
        # no references at all
        no_refs = Dict{String, Any}(
            "__metadata__" => Dict("type" => "ACBus"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-no-refs")),
            "name" => "nodeB",
            "number" => 2,
        )
        @test !PSU.references_skipped(no_refs, led)

        # a reference buried inside a vector field points at a skipped component
        vector_orphan = Dict{String, Any}(
            "__metadata__" => Dict("type" => "SomeType"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-vector-orphan")),
            "arcs" => [Dict("value" => "uuid-bus"), Dict("value" => "uuid-gone")],
        )
        @test PSU.references_skipped(vector_orphan, led)

        # a vector field whose references are all live is not flagged
        vector_live = Dict{String, Any}(
            "__metadata__" => Dict("type" => "SomeType"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-vector-live")),
            "arcs" => [Dict("value" => "uuid-bus"), Dict("value" => "uuid-area")],
        )
        @test !PSU.references_skipped(vector_live, led)
    end

    @testset "build_kwargs drops nothing and internal fields" begin
        @test !haskey(kwargs, :load_zone)
        for internal_key in PSU.PSY5_INTERNAL_FIELDS
            @test !haskey(kwargs, Symbol(internal_key))
        end
    end

    @testset "nested composite shapes match PSY5 pass-through" begin
        # build_kwargs forwards non-reference nested dicts verbatim, so PSY5's key
        # shape must stay identical to the PSY6 model's fieldnames. Drift here would
        # be silent: these fields carry no type annotation in the generated models.
        expected = Dict(
            :MinMax => Set([:min, :max]),
            :FromTo => Set([:from, :to]),
            :UpDown => Set([:up, :down]),
            :InOut => Set([:in, :out]),
        )
        for (name, keys) in expected
            @test Set(fieldnames(getfield(PSU.POM, name))) == keys
        end
    end

    @testset "oneOf discriminator injection" begin
        # one row per PSY6 union in the fix-round spec; property name and value both
        # asserted exactly, so a wrong value (not just a missing key) would fail here.
        cases = [
            ("ProductionVariableCostCurve", "CostCurve", :variable_cost_type, "COST"),
            ("ProductionVariableCostCurve", "FuelCurve", :variable_cost_type, "FUEL"),
            ("ValueCurve", "InputOutputCurve", :curve_type, "INPUT_OUTPUT"),
            ("ValueCurve", "IncrementalCurve", :curve_type, "INCREMENTAL"),
            ("ValueCurve", "AverageRateCurve", :curve_type, "AVERAGE_RATE"),
            ("FunctionData", "LinearFunctionData", :function_type, "LINEAR"),
            ("FunctionData", "QuadraticFunctionData", :function_type, "QUADRATIC"),
            ("FunctionData", "PiecewiseLinearData", :function_type, "PIECEWISE_LINEAR"),
            ("FunctionData", "PiecewiseStepData", :function_type, "PIECEWISE_STEP"),
            # TwoTerminalLoss reads the same property off the same two PSY5 types as
            # ValueCurve, and the spec says the value is identical either way.
            ("TwoTerminalLoss", "IncrementalCurve", :curve_type, "INCREMENTAL"),
            ("TwoTerminalLoss", "InputOutputCurve", :curve_type, "INPUT_OUTPUT"),
            ("GenericOperationCost", "RenewableGenerationCost", :cost_type, "RENEWABLE"),
            ("GenericOperationCost", "ThermalGenerationCost", :cost_type, "THERMAL"),
            ("GenericOperationCost", "HydroGenerationCost", :cost_type, "HYDRO_GEN"),
            # HydroStorageGenerationCost reads the same property off HydroGenerationCost
            # as GenericOperationCost, again with the same value.
            ("HydroStorageGenerationCost", "HydroGenerationCost", :cost_type, "HYDRO_GEN"),
            ("HydroStorageGenerationCost", "StorageCost", :cost_type, "STORAGE"),
        ]
        for (union, psy5_type, property, value) in cases
            raw_value = Dict{String, Any}(
                "__metadata__" => Dict("module" => "PowerSystems", "type" => psy5_type),
                "some_field" => 1.0,
            )
            translated = PSU.translate_value(raw_value, led)
            @test translated[String(property)] == value
            @test translated["__metadata__"]["type"] == psy5_type
            @test translated["some_field"] == 1.0
        end

        # nesting: a CostCurve's value_curve is an InputOutputCurve, whose function_data
        # is a LinearFunctionData — all three need their own discriminator in one pass.
        nested = Dict{String, Any}(
            "__metadata__" => Dict("type" => "CostCurve"),
            "value_curve" => Dict{String, Any}(
                "__metadata__" => Dict("type" => "InputOutputCurve"),
                "function_data" => Dict{String, Any}(
                    "__metadata__" => Dict("type" => "LinearFunctionData"),
                    "constant_term" => 0.0,
                    "proportional_term" => 30.0,
                ),
            ),
        )
        translated_nested = PSU.translate_value(nested, led)
        @test translated_nested["variable_cost_type"] == "COST"
        @test translated_nested["value_curve"]["curve_type"] == "INPUT_OUTPUT"
        @test translated_nested["value_curve"]["function_data"]["function_type"] ==
              "LINEAR"

        # a PSY5 type not in the table is forwarded unchanged, discriminator or not
        untagged = Dict{String, Any}(
            "__metadata__" => Dict("type" => "SomeUnrelatedType"),
            "field" => 1,
        )
        @test !haskey(PSU.translate_value(untagged, led), "curve_type")
        @test PSU.translate_value(untagged, led)["field"] == 1

        # StartUpStages carries no __metadata__ at all in PSY5, so it is detected by its
        # exact key set rather than a type tag.
        start_up_stages = Dict{String, Any}("hot" => 1.0, "warm" => 2.0, "cold" => 3.0)
        translated_stages = PSU.translate_value(start_up_stages, led)
        @test translated_stages["startup_stages_type"] == "STAGES"

        # a plain composite with a disjoint key set is not mistaken for StartUpStages
        min_max = Dict{String, Any}("min" => 0.0, "max" => 1.0)
        @test !haskey(PSU.translate_value(min_max, led), "startup_stages_type")
    end

    @testset "unmapped field counts accumulate across calls" begin
        counting_rep = PSU.ConversionReport()
        raw_with_extra = Dict{String, Any}(
            "__metadata__" => Dict("type" => "ACBus"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-count-1")),
            "name" => "nodeC",
            "not_a_psy6_field" => 1,
        )
        raw_with_extra_2 = Dict{String, Any}(
            "__metadata__" => Dict("type" => "ACBus"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-count-2")),
            "name" => "nodeD",
            "not_a_psy6_field" => 2,
        )
        PSU.build_kwargs(ACBus, raw_with_extra, led, counting_rep)
        @test counting_rep.unmapped_fields[("ACBus", "not_a_psy6_field")] == 1
        PSU.build_kwargs(ACBus, raw_with_extra_2, led, counting_rep)
        @test counting_rep.unmapped_fields[("ACBus", "not_a_psy6_field")] == 2
    end
end
