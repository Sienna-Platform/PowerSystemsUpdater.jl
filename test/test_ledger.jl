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

    @testset "lookup_id throws on a skipped uuid, regardless of assignment order" begin
        # id assignment always runs in a pass over every component before translation
        # decides anything is skipped, so a skipped uuid still has a live id in
        # ledger.ids by the time it is marked skipped. lookup_id must refuse it anyway:
        # it is the funnel every reference resolution passes through, so this holds no
        # matter which order the two writes (assign_id!, mark_skipped!) happened in.
        led5 = PSU.Ledger()
        PSU.assign_id!(led5, "uuid-order-a")
        PSU.mark_skipped!(led5, "uuid-order-a", "no PSY6 schema for Widget")
        @test PSU.has_id(led5, "uuid-order-a")
        @test_throws PSU.DanglingReferenceError PSU.lookup_id(led5, "uuid-order-a")

        # the reverse write order behaves identically.
        led6 = PSU.Ledger()
        PSU.mark_skipped!(led6, "uuid-order-b", "no PSY6 schema for Widget")
        PSU.assign_id!(led6, "uuid-order-b")
        @test_throws PSU.DanglingReferenceError PSU.lookup_id(led6, "uuid-order-b")
    end
end
