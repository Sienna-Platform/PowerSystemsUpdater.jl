@testset "ledger" begin
    led = PSU.Ledger()

    a = PSU.assign_id!(led, "uuid-a")
    b = PSU.assign_id!(led, "uuid-b")
    @test a == 1
    @test b == 2
    @test PSU.assign_id!(led, "uuid-a") == 1      # idempotent
    @test PSU.has_id(led, "uuid-a")
    @test !PSU.has_id(led, "uuid-never-assigned")
    @test PSU.lookup_id(led, "uuid-b") == 2
    @test_throws PSU.DanglingReferenceError PSU.lookup_id(led, "uuid-nonexistent")

    synth = PSU.allocate_id!(led)
    @test synth == 3
    @test synth != a && synth != b

    @test !PSU.is_skipped(led, "uuid-a")
    PSU.mark_skipped!(led, "uuid-c", "no PSY6 schema for Widget")
    @test PSU.is_skipped(led, "uuid-c")
    @test occursin("Widget", PSU.skip_reason(led, "uuid-c"))

    @test PSU.is_reference(Dict("value" => "uuid-a"))
    @test !PSU.is_reference(Dict("min" => 0.9, "max" => 1.05))
    @test !PSU.is_reference(1.0)
    @test !PSU.is_reference(Dict("value" => 5))
    @test PSU.reference_uuid(Dict("value" => "uuid-a")) == "uuid-a"
end
