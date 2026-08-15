@testset "report" begin
    rep = PSU.ConversionReport()
    @test !PSU.has_findings(rep)

    PSU.record_unmapped_type!(rep, "Widget")
    PSU.record_unmapped_type!(rep, "Widget")
    PSU.record_cascaded_skip!(rep, "Line")
    PSU.record_unmapped_field!(rep, "Line", "winding_group_number")

    @test PSU.has_findings(rep)
    @test rep.unmapped_types["Widget"] == 2
    @test rep.cascaded_skips["Line"] == 1
    @test rep.unmapped_fields[("Line", "winding_group_number")] == 1

    PSU.record_unmapped_type!(rep, "Aardvark")
    text = sprint(show, MIME("text/plain"), rep)
    @test occursin("Widget", text)
    @test occursin("winding_group_number", text)
    @test occursin("x2", text)
    @test occursin("CASCADED SKIPS", text)
    @test occursin("UNMAPPED FIELDS", text)
    @test findfirst("Aardvark", text)[1] < findfirst("Widget", text)[1]
end

@testset "report shows empty state" begin
    @test occursin("no findings", sprint(show, MIME("text/plain"), PSU.ConversionReport()))
end
