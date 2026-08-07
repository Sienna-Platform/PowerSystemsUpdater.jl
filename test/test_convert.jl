@testset "convert_system" begin
    dir = joinpath(@__DIR__, "..", "data", "PSITestSystems")
    path = joinpath(dir, "c_sys5")
    if require_corpus_file(path)
        mktempdir() do tmp
            report = PSU.convert_system(path, tmp)

            system_json = joinpath(tmp, "system.json")
            @test isfile(system_json)

            doc = PSU.PCOM.read_document(system_json)
            @test PSU.PCOM.get_unit_system(doc) == "DEVICE_BASE"
            @test PSU.PCOM.get_base_power(doc) == 100.0
            @test !isempty(PSU.PCOM.get_components(doc, "ACBus"))

            @test isempty(report.unmapped_types)
            @test isempty(report.cascaded_skips)
        end
    end
end

@testset "convert_system: round trip with a FuelCurve" begin
    dir = joinpath(@__DIR__, "..", "data", "PSITestSystems")
    path = joinpath(dir, "c_linear_fuel_test")
    if require_corpus_file(path)
        mktempdir() do tmp
            PSU.convert_system(path, tmp)
            system_json = joinpath(tmp, "system.json")
            raw = PSU.JSON.parsefile(system_json; dicttype = Dict{String, Any})
            fuel_curves = [
                thermal["operation_cost"]["variable"] for
                thermal in raw["components"]["ThermalStandard"] if
                thermal["operation_cost"]["variable"]["variable_cost_type"] == "FUEL"
            ]
            @test !isempty(fuel_curves)

            doc = PSU.PCOM.read_document(system_json)
            for type_name in PSU.PCOM.component_type_names(doc)
                @test length(PSU.PCOM.get_components(doc, type_name)) ==
                      length(raw["components"][type_name])
            end
        end
    end
end

@testset "convert_system: a nested FuelCurve field with no PSY6 counterpart is recorded" begin
    # 5_bus_hydro_ed_sys's HydroDispatch carries operation_cost.variable.startup_fuel_offtake,
    # a real PSY5 field inside a nested FuelCurve that no PSY6 schema declares. Before the
    # fix, translate_value forwarded nested dict keys with no filtering at all, so this was
    # emitted into output silently instead of being recorded like an unmapped top-level field.
    dir = joinpath(@__DIR__, "..", "data", "PSISystems")
    path = joinpath(dir, "5_bus_hydro_ed_sys")
    if require_corpus_file(path)
        mktempdir() do tmp
            report = PSU.convert_system(path, tmp)
            @test report.unmapped_fields[("FuelCurve", "startup_fuel_offtake")] > 0
        end
    end
end

@testset "convert_system: round trip with a HydroReservoir" begin
    dir = joinpath(@__DIR__, "..", "data", "PSITestSystems")
    path = joinpath(dir, "c_sys5_hy_uc")
    if require_corpus_file(path)
        mktempdir() do tmp
            report = PSU.convert_system(path, tmp)
            system_json = joinpath(tmp, "system.json")
            raw = PSU.JSON.parsefile(system_json; dicttype = Dict{String, Any})
            @test !isempty(raw["components"]["HydroReservoir"])

            doc = PSU.PCOM.read_document(system_json)
            for type_name in PSU.PCOM.component_type_names(doc)
                @test length(PSU.PCOM.get_components(doc, type_name)) ==
                      length(raw["components"][type_name])
            end
            @test isempty(report.unmapped_types)
        end
    end
end

@testset "convert_system: MarketBidCost scalar cost fields (documented schema gap, not fixed)" begin
    # PSY6's MarketBidCost.no_load_cost/shut_down are typed as the concrete InputOutputCurve
    # struct (SiennaSchemas/Core/common.json), with no oneOf/anyOf admitting a bare number —
    # only a *default* curve for when the field is omitted, which is not the same as a
    # sanctioned scalar instance value. PSY5's HybridSystem-level MarketBidCost writes
    # shut_down as a bare Float64, so this is left failing rather than guessing at an
    # unsanctioned promotion; see task-11-report.md fix round 2.
    dir = joinpath(@__DIR__, "..", "data", "PSITestSystems")
    path = joinpath(dir, "c_sys5_hybrid")
    if require_corpus_file(path)
        mktempdir() do tmp
            PSU.convert_system(path, tmp)
            system_json = joinpath(tmp, "system.json")
            raw = PSU.JSON.parsefile(system_json; dicttype = Dict{String, Any})
            shut_downs =
                [
                    h["operation_cost"]["shut_down"] for
                    h in raw["components"]["HybridSystem"]
                ]
            @test !isempty(shut_downs)
            @test all(value -> typeof(value) === Float64, shut_downs)

            @test_throws MethodError PSU.PCOM.read_document(system_json)
        end
    end
end

@testset "convert_system: hybrid systems convert without throwing" begin
    dir = joinpath(@__DIR__, "..", "data", "PSITestSystems")
    for name in
        (
        "c_sys5_hybrid",
        "c_sys5_hybrid_uc",
        "c_sys5_hybrid_ed",
        "test_RTS_GMLC_sys_with_hybrid",
    )
        path = joinpath(dir, name)
        if !require_corpus_file(path)
            continue
        end
        mktempdir() do tmp
            report = PSU.convert_system(path, tmp)
            @test isfile(joinpath(tmp, "system.json"))
            @test isempty(report.unmapped_types)
        end
    end
end

@testset "convert_system: with time series" begin
    dir = joinpath(@__DIR__, "..", "data", "PSITestSystems")
    path = joinpath(dir, "c_sys5")
    if require_corpus_file(path)
        mktempdir() do tmp
            PSU.convert_system(path, tmp)
            @test isfile(joinpath(tmp, "time_series.h5"))
            raw = PSU.JSON.parsefile(
                joinpath(tmp, "system.json");
                dicttype = Dict{String, Any},
            )
            @test raw["time_series_storage_file"] == "time_series.h5"
            @test !isempty(raw["time_series_associations"])
        end
    end
end

@testset "convert_system: without time series" begin
    dir = joinpath(@__DIR__, "..", "data", "PSITestSystems")
    path = joinpath(dir, "case10_radial_series_reductions")
    if require_corpus_file(path)
        mktempdir() do tmp
            PSU.convert_system(path, tmp)
            @test !isfile(joinpath(tmp, "time_series.h5"))
            raw = PSU.JSON.parsefile(
                joinpath(tmp, "system.json");
                dicttype = Dict{String, Any},
            )
            @test isnothing(raw["time_series_storage_file"])
        end
    end
end

@testset "convert_system: force semantics" begin
    dir = joinpath(@__DIR__, "..", "data", "PSITestSystems")
    path = joinpath(dir, "c_sys5")
    if require_corpus_file(path)
        mktempdir() do tmp
            PSU.convert_system(path, tmp)
            @test_throws PSU.PCOM.DocumentFormatError PSU.convert_system(path, tmp)
            report = PSU.convert_system(path, tmp; force = true)
            @test isfile(joinpath(tmp, "system.json"))
            @test !isempty(report.systems)
        end
    end
end

@testset "build_document: id disjointness and supplemental attributes" begin
    path = joinpath(@__DIR__, "..", "data", "CATS", "CATS_Sienna.json")
    if require_corpus_file(path)
        case = PSU.read_psy5(path)
        report = PSU.ConversionReport()
        doc, _ = PSU.build_document(case, report)

        component_ids = Int[]
        for type_name in PSU.PCOM.component_type_names(doc)
            for component in PSU.PCOM.get_components(doc, type_name)
                push!(component_ids, component.id)
            end
        end
        @test length(component_ids) == length(Set(component_ids))

        attribute_ids = [a.id for a in doc.supplemental_attributes]
        @test length(attribute_ids) == length(Set(attribute_ids))
        @test isempty(intersect(Set(component_ids), Set(attribute_ids)))

        geo_associations = filter(
            a -> a.attribute_type == "GeographicInfo",
            doc.supplemental_attribute_associations,
        )
        @test !isempty(geo_associations)
        geo_ids = Set(a.id for a in doc.supplemental_attributes)
        @test all(a -> a.attribute_id in geo_ids, geo_associations)
        @test all(a -> a.entity_id in Set(component_ids), geo_associations)

        @test PSU.PCOM.get_unit_system(doc) == "DEVICE_BASE"
        @test PSU.PCOM.get_base_power(doc) == PSU.system_base_power(case)
    end
end

@testset "build_document: HybridSystem cascades when a masked sub-unit is skipped" begin
    raw_data = Dict{String, Any}(
        "components" => Any[
            Dict{String, Any}(
                "__metadata__" => Dict("type" => "HybridSystem"),
                "internal" => Dict("uuid" => Dict("value" => "uuid-hybrid")),
                "name" => "hybrid1",
                "available" => true,
                "status" => true,
                "bus" => Dict("value" => "uuid-bus"),
                "active_power" => 1.0,
                "reactive_power" => 0.0,
                "base_power" => 100.0,
                "thermal_unit" => Dict("value" => "uuid-thermal"),
            ),
            Dict{String, Any}(
                "__metadata__" => Dict("type" => "ACBus"),
                "internal" => Dict("uuid" => Dict("value" => "uuid-bus")),
                "name" => "bus1",
                "number" => 1,
                "available" => true,
                "bustype" => "REF",
            ),
        ],
        "masked_components" => Any[
            Dict{String, Any}(
            "__metadata__" => Dict("type" => "SomeUnmappedGeneratorType"),
            "internal" => Dict("uuid" => Dict("value" => "uuid-thermal")),
            "name" => "gen1",
        ),
        ],
    )
    raw = Dict{String, Any}(
        "data" => raw_data,
        "units_settings" => Dict("base_value" => 100.0),
        "frequency" => 60.0,
        "metadata" => Dict{String, Any}("name" => nothing, "description" => nothing),
        "data_format_version" => "5.0.0",
    )
    case = PSU.Psy5Case(raw, "test-hybrid-cascade", nothing)
    report = PSU.ConversionReport()
    doc, ledger = PSU.build_document(case, report)

    @test report.unmapped_types["SomeUnmappedGeneratorType"] == 1
    @test report.cascaded_skips["HybridSystem"] == 1
    @test PSU.is_skipped(ledger, "uuid-hybrid")
    @test isempty(PSU.PCOM.get_components(doc, "HybridSystem"))
end

@testset "build_document: one supplemental attribute shared by two owners" begin
    raw_data = Dict{String, Any}(
        "components" => Any[
            Dict{String, Any}(
                "__metadata__" => Dict("type" => "ACBus"),
                "internal" => Dict("uuid" => Dict("value" => "uuid-bus-a")),
                "name" => "busA", "number" => 1, "available" => true,
                "bustype" => "REF",
            ),
            Dict{String, Any}(
                "__metadata__" => Dict("type" => "ACBus"),
                "internal" => Dict("uuid" => Dict("value" => "uuid-bus-b")),
                "name" => "busB", "number" => 2, "available" => true,
                "bustype" => "REF",
            ),
        ],
        "supplemental_attribute_manager" => Dict{String, Any}(
            "attributes" => Any[
                Dict{String, Any}(
                "__metadata__" => Dict("type" => "GeographicInfo"),
                "internal" => Dict("uuid" => Dict("value" => "uuid-geo")),
                "geo_json" => Dict{String, Any}("type" => "Point"),
            ),
            ],
            "associations" => Any[
                Dict{String, Any}(
                    "attribute_uuid" => "uuid-geo",
                    "attribute_type" => "GeographicInfo",
                    "component_uuid" => "uuid-bus-a",
                    "component_type" => "ACBus",
                ),
                Dict{String, Any}(
                    "attribute_uuid" => "uuid-geo",
                    "attribute_type" => "GeographicInfo",
                    "component_uuid" => "uuid-bus-b",
                    "component_type" => "ACBus",
                ),
            ],
        ),
    )
    raw = Dict{String, Any}(
        "data" => raw_data,
        "units_settings" => Dict("base_value" => 100.0),
        "frequency" => 60.0,
        "metadata" => Dict{String, Any}("name" => nothing, "description" => nothing),
        "data_format_version" => "5.0.0",
    )
    case = PSU.Psy5Case(raw, "test-shared-attribute", nothing)
    report = PSU.ConversionReport()
    doc, _ = PSU.build_document(case, report)

    # the shared attribute is pushed once, not once per owner.
    @test length(doc.supplemental_attributes) == 1

    geo_associations = filter(
        a -> a.attribute_type == "GeographicInfo",
        doc.supplemental_attribute_associations,
    )
    @test length(geo_associations) == 2
    @test length(Set(a.entity_id for a in geo_associations)) == 2
    @test length(Set(a.attribute_id for a in geo_associations)) == 1

    PSU.PCOM.validate_document(doc)
end
