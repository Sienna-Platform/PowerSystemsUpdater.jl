@testset "base_power synthesis" begin
    declared = Dict{String, Any}("base_power" => 30.0)
    @test PSU.base_power_for(declared, 100.0) == 30.0

    undeclared = Dict{String, Any}("r" => 0.01)
    @test PSU.base_power_for(undeclared, 100.0) == 100.0

    explicit_nothing = Dict{String, Any}("base_power" => nothing)
    @test PSU.base_power_for(explicit_nothing, 100.0) == 100.0

    declared_int = Dict{String, Any}("base_power" => 30)
    result_int = PSU.base_power_for(declared_int, 100.0)
    @test result_int == 30.0
    @test typeof(result_int) === Float64

    undeclared_int_system = Dict{String, Any}("r" => 0.01)
    result_system_int = PSU.base_power_for(undeclared_int_system, 100)
    @test result_system_int == 100.0
    @test typeof(result_system_int) === Float64

    different_bases = Dict{String, Any}("base_power" => 50.0)
    @test PSU.base_power_for(different_bases, 100.0) == 50.0
    @test PSU.base_power_for(different_bases, 200.0) == 50.0

    # Function does not invent validation policy; pass through invalid (zero, negative) values unchanged.
    zero_base = Dict{String, Any}("base_power" => 0.0)
    @test PSU.base_power_for(zero_base, 100.0) == 0.0

    negative_base = Dict{String, Any}("base_power" => -5.0)
    @test PSU.base_power_for(negative_base, 100.0) == -5.0
end
