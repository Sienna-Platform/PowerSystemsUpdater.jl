@testset "convert_system" begin
    dir = joinpath(@__DIR__, "..", "data", "PSITestSystems")
    path = joinpath(dir, "c_sys5")
    if !isfile(path)
        @warn "corpus absent; skipping convert test" path
    else
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
    if !isfile(path)
        @warn "corpus absent; skipping" path
    else
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
        if !isfile(path)
            @warn "corpus absent; skipping" path
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
    if !isfile(path)
        @warn "corpus absent; skipping" path
    else
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
    if !isfile(path)
        @warn "corpus absent; skipping" path
    else
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
    if !isfile(path)
        @warn "corpus absent; skipping" path
    else
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
    if !isfile(path)
        @warn "CATS corpus absent; skipping" path
    else
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
