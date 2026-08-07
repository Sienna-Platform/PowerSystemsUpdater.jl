@testset "read_psy5" begin
    dir = joinpath(@__DIR__, "..", "data", "PSITestSystems")
    path = joinpath(dir, "c_sys5")
    if require_corpus_file(path)
        case = PSU.read_psy5(path)
        @test PSU.system_base_power(case) == 100.0
        @test !isempty(PSU.components(case))
        @test PSU.has_time_series(case)
        @test endswith(case.time_series_path, "c_sys5_time_series_storage.h5")

        first_bus = first(c for c in PSU.components(case)
              if PSU.component_type(c) == "ACBus")
        @test PSU.component_type(first_bus) == "ACBus"
        @test isempty(PSU.component_parameters(first_bus))
    end

    mktempdir() do tmp
        bad = joinpath(tmp, "bad")
        write(bad, """{"data_format_version":"4.0.0","data":{"components":[]}}""")
        @test_throws PSU.Psy5FormatError PSU.read_psy5(bad)
    end
end
