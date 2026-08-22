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
        @test PSU.translate_value(42, led, rep) == 42
        @test PSU.translate_value("plain-string", led, rep) == "plain-string"
        @test PSU.translate_value(3.14, led, rep) == 3.14
        @test PSU.translate_value(nothing, led, rep) === nothing

        # a non-reference dict passes through unchanged
        plain_dict = Dict("min" => 0.9, "max" => 1.05)
        @test PSU.translate_value(plain_dict, led, rep) == plain_dict

        # a vector of references resolves each element
        refs = [Dict("value" => "uuid-bus"), Dict("value" => "uuid-area")]
        @test PSU.translate_value(refs, led, rep) == [bus_id, area_id]

        # a vector mixing references and scalars resolves only the references
        mixed = [Dict("value" => "uuid-bus"), 7, "tag"]
        @test PSU.translate_value(mixed, led, rep) == [bus_id, 7, "tag"]
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
            discriminator_rep = PSU.ConversionReport()
            translated = PSU.translate_value(raw_value, led, discriminator_rep)
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
        nested_rep = PSU.ConversionReport()
        translated_nested = PSU.translate_value(nested, led, nested_rep)
        @test translated_nested["variable_cost_type"] == "COST"
        @test translated_nested["value_curve"]["curve_type"] == "INPUT_OUTPUT"
        @test translated_nested["value_curve"]["function_data"]["function_type"] ==
              "LINEAR"
        @test isempty(nested_rep.unmapped_fields)

        # a PSY5 type not in the table is forwarded unchanged, discriminator or not
        untagged = Dict{String, Any}(
            "__metadata__" => Dict("type" => "SomeUnrelatedType"),
            "field" => 1,
        )
        untagged_rep = PSU.ConversionReport()
        @test !haskey(PSU.translate_value(untagged, led, untagged_rep), "curve_type")
        @test PSU.translate_value(untagged, led, untagged_rep)["field"] == 1

        # StartUpStages carries no __metadata__ at all in PSY5, so it is detected by its
        # exact key set rather than a type tag.
        start_up_stages = Dict{String, Any}("hot" => 1.0, "warm" => 2.0, "cold" => 3.0)
        stages_rep = PSU.ConversionReport()
        translated_stages = PSU.translate_value(start_up_stages, led, stages_rep)
        @test translated_stages["startup_stages_type"] == "STAGES"
        @test isempty(stages_rep.unmapped_fields)

        # a plain composite with a disjoint key set is not mistaken for StartUpStages
        min_max = Dict{String, Any}("min" => 0.0, "max" => 1.0)
        min_max_rep = PSU.ConversionReport()
        @test !haskey(
            PSU.translate_value(min_max, led, min_max_rep),
            "startup_stages_type",
        )
    end

    @testset "nested composite fields with no PSY6 counterpart are recorded, not dropped" begin
        # `not_a_psy6_field` is synthetic (FuelCurve declares no such field in any PSY6
        # schema; unlike its real `startup_fuel_offtake`, added by the schema regen this
        # test suite now runs against -- see "FuelCurve.startup_fuel_offtake round-trips" in
        # test_convert.jl). A nested FuelCurve carrying an unmapped key must be caught the
        # same way build_kwargs catches an unmapped top-level field, not forwarded into the
        # output silently.
        fuel_curve_rep = PSU.ConversionReport()
        fuel_curve = Dict{String, Any}(
            "__metadata__" =>
                Dict("module" => "InfrastructureSystems", "type" => "FuelCurve"),
            "fuel_cost" => 0.0,
            "power_units" => "NATURAL_UNITS",
            "value_curve" => Dict{String, Any}(
                "__metadata__" => Dict("type" => "InputOutputCurve"),
                "function_data" => Dict{String, Any}(
                    "__metadata__" => Dict("type" => "LinearFunctionData"),
                    "constant_term" => 0.0,
                    "proportional_term" => 0.0,
                ),
            ),
            "not_a_psy6_field" => Dict{String, Any}(
                "__metadata__" => Dict("type" => "InputOutputCurve"),
                "function_data" => Dict{String, Any}(
                    "__metadata__" => Dict("type" => "LinearFunctionData"),
                    "constant_term" => 0.0,
                    "proportional_term" => 0.0,
                ),
            ),
        )
        translated_fuel = PSU.translate_value(fuel_curve, led, fuel_curve_rep)
        @test haskey(translated_fuel, "not_a_psy6_field")
        @test fuel_curve_rep.unmapped_fields[("FuelCurve", "not_a_psy6_field")] == 1

        # a buried reference to an already-skipped uuid is caught however deep it is
        # nested, since the fast path (references_skipped) does not recurse into a
        # non-reference dict but translate_value/lookup_id does.
        deep_rep = PSU.ConversionReport()
        PSU.mark_skipped!(led, "uuid-buried-skip", "no PSY6 schema for Widget")
        buried = Dict{String, Any}(
            "__metadata__" => Dict("type" => "SomeUnrelatedType"),
            "wrapper" =>
                Dict{String, Any}("inner" => Dict("value" => "uuid-buried-skip")),
        )
        @test !PSU.is_reference(buried["wrapper"])
        @test_throws PSU.DanglingReferenceError PSU.translate_value(buried, led, deep_rep)
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

    @testset "MarketBidCost scalar shut_down/no_load_cost promoted to a curve" begin
        # PSY5 legally writes a bare Float64; PSY6 types both fields as a concrete
        # InputOutputCurve. Real corpus systems (c_sys5_hybrid and siblings) hit this.
        scalar_rep = PSU.ConversionReport()
        raw = Dict{String, Any}(
            "__metadata__" => Dict("type" => "MarketBidCost"),
            "cost_type" => "MARKET_BID",
            "shut_down" => 0.0,
            "no_load_cost" => 12.5,
        )
        translated = PSU.translate_value(raw, led, scalar_rep)
        @test translated["shut_down"]["__metadata__"]["type"] == "InputOutputCurve"
        @test translated["shut_down"]["curve_type"] == "INPUT_OUTPUT"
        @test translated["shut_down"]["input_at_zero"] === nothing
        @test translated["shut_down"]["function_data"]["__metadata__"]["type"] ==
              "LinearFunctionData"
        @test translated["shut_down"]["function_data"]["function_type"] == "LINEAR"
        @test translated["shut_down"]["function_data"]["constant_term"] == 0.0
        @test translated["shut_down"]["function_data"]["proportional_term"] == 0.0
        @test translated["no_load_cost"]["function_data"]["constant_term"] == 12.5
        @test translated["no_load_cost"]["function_data"]["proportional_term"] == 0.0
        @test isempty(scalar_rep.unmapped_fields)

        # actually constructs: OpenAPI.from_json is what POM.read_document uses to turn
        # a JSON dict into a typed model, and this is the exact call that raised
        # "MethodError: Cannot convert an object of type Float64 to ... InputOutputCurve"
        # before this fix.
        json_ready = Dict{String, Any}("cost_type" => "MARKET_BID")
        for (key, value) in translated
            if key == "__metadata__"
                continue
            end
            json_ready[key] = value
        end
        model = PSU.OpenAPI.from_json(PSU.POM.MarketBidCost, json_ready)
        @test typeof(model.shut_down) === PSU.PCOM.InputOutputCurve
        # function_data is itself a discriminated oneOf; .value holds the resolved type.
        @test model.shut_down.function_data.value.constant_term == 0.0
        @test model.shut_down.function_data.value.proportional_term == 0.0
        @test model.no_load_cost.function_data.value.constant_term == 12.5

        # scoped narrowly: a scalar named "shut_down" on any other type is left alone
        other_rep = PSU.ConversionReport()
        unrelated = Dict{String, Any}(
            "__metadata__" => Dict("type" => "SomeUnrelatedType"),
            "shut_down" => 0.0,
        )
        @test PSU.translate_value(unrelated, led, other_rep)["shut_down"] == 0.0

        # a non-scalar shut_down (already a proper curve dict) is left for the ordinary
        # discriminator-injection path, not double-promoted
        curve_rep = PSU.ConversionReport()
        already_curve = Dict{String, Any}(
            "__metadata__" => Dict("type" => "MarketBidCost"),
            "shut_down" => Dict{String, Any}(
                "__metadata__" => Dict("type" => "InputOutputCurve"),
                "function_data" => Dict{String, Any}(
                    "__metadata__" => Dict("type" => "LinearFunctionData"),
                    "constant_term" => 5.0,
                    "proportional_term" => 1.0,
                ),
            ),
        )
        translated_curve = PSU.translate_value(already_curve, led, curve_rep)
        @test translated_curve["shut_down"]["function_data"]["constant_term"] == 5.0
        @test translated_curve["shut_down"]["function_data"]["proportional_term"] == 1.0
    end

    @testset "embedded time-series pointers error loudly" begin
        # PSY5 sometimes embeds a live time-series reference directly in a value field
        # instead of a literal value. PSY6 has no field type for that, so it must throw
        # rather than convert a bogus value or drop the pointer silently.
        forecast_key_rep = PSU.ConversionReport()
        fuel_curve = Dict{String, Any}(
            "__metadata__" => Dict("type" => "FuelCurve"),
            "power_units" => "NATURAL_UNITS",
            "fuel_cost" => Dict{String, Any}(
                "__metadata__" => Dict("type" => "ForecastKey"),
                "name" => "fuel_cost",
            ),
        )
        err = try
            PSU.translate_value(fuel_curve, led, forecast_key_rep)
            nothing
        catch e
            e
        end
        @test typeof(err) === PSU.Psy5FormatError
        message = sprint(showerror, err)
        @test occursin("FuelCurve.fuel_cost", message)
        @test occursin("ForecastKey", message)

        static_ts_key_rep = PSU.ConversionReport()
        market_bid = Dict{String, Any}(
            "__metadata__" => Dict("type" => "MarketBidCost"),
            "incremental_offer_curves" => Dict{String, Any}(
                "__metadata__" => Dict("type" => "StaticTimeSeriesKey"),
                "name" => "variable_cost",
            ),
        )
        static_err = try
            PSU.translate_value(market_bid, led, static_ts_key_rep)
            nothing
        catch e
            e
        end
        @test typeof(static_err) === PSU.Psy5FormatError
        static_message = sprint(showerror, static_err)
        @test occursin("MarketBidCost.incremental_offer_curves", static_message)
        @test occursin("StaticTimeSeriesKey", static_message)

        # a dict that merely looks like it might be a pointer (wrong type name) is left
        # alone
        harmless_rep = PSU.ConversionReport()
        harmless = Dict{String, Any}(
            "__metadata__" => Dict("type" => "FuelCurve"),
            "fuel_cost" => 3.5,
        )
        @test PSU.translate_value(harmless, led, harmless_rep)["fuel_cost"] == 3.5
    end
end
