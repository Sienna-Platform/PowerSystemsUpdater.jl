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
