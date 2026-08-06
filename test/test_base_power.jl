@testset "base_power synthesis" begin
    # Case 1: declared base_power returns the declared value
    declared = Dict{String, Any}("base_power" => 30.0)
    @test PSU.base_power_for(declared, 100.0) == 30.0

    # Case 2: undeclared base_power returns the system base
    undeclared = Dict{String, Any}("r" => 0.01)
    @test PSU.base_power_for(undeclared, 100.0) == 100.0

    # Case 3: explicit nothing base_power returns the system base
    explicit_nothing = Dict{String, Any}("base_power" => nothing)
    @test PSU.base_power_for(explicit_nothing, 100.0) == 100.0

    # Extra tests for type conversions and edge cases

    # Integer base_power is converted to Float64
    declared_int = Dict{String, Any}("base_power" => 30)
    result_int = PSU.base_power_for(declared_int, 100.0)
    @test result_int == 30.0
    @test result_int isa Float64

    # Integer system_base is converted to Float64
    undeclared_int_system = Dict{String, Any}("r" => 0.01)
    result_system_int = PSU.base_power_for(undeclared_int_system, 100)
    @test result_system_int == 100.0
    @test result_system_int isa Float64

    # Declared base_power differs from system base: declared is returned
    different_bases = Dict{String, Any}("base_power" => 50.0)
    @test PSU.base_power_for(different_bases, 100.0) == 50.0
    @test PSU.base_power_for(different_bases, 200.0) == 50.0

    # Zero base_power is passed through unchanged (no silent correction)
    zero_base = Dict{String, Any}("base_power" => 0.0)
    @test PSU.base_power_for(zero_base, 100.0) == 0.0

    # Negative base_power is passed through unchanged (no silent correction)
    negative_base = Dict{String, Any}("base_power" => -5.0)
    @test PSU.base_power_for(negative_base, 100.0) == -5.0
end
