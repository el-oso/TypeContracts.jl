@testitem "check_trim_compat — clean methods" setup = [TCFixtures] begin
    using Test
    using TypeContracts
    using .TCFixtures

    # TLabrador implements animal_speak and dog_fetch with plain Julia code.
    result = check_trim_compat(TLabrador)
    @test result.passed
    @test isempty(result.issues)
    @test result.type === TLabrador

    # IntBucket implements bget, bset!, blen — all simple array ops.
    result2 = check_trim_compat(IntBucket)
    @test result2.passed
    @test isempty(result2.issues)
end

@testitem "check_trim_compat — trim-unsafe method" setup = [TCFixtures] begin
    using Test
    using TypeContracts

    # Define a contract and a type whose mandatory method calls Base.return_types.
    abstract type AbstractTrimBad end
    function tbad_fn end
    @contract AbstractTrimBad begin
        tbad_fn(::Self)::Float64
    end
    struct TrimBadImpl <: AbstractTrimBad end
    # Implementation intentionally calls Base.return_types — trim-unsafe.
    tbad_fn(::TrimBadImpl)::Float64 =
        Float64(length(Base.return_types(tbad_fn, Tuple{TrimBadImpl})))

    check_contract(TrimBadImpl)  # structural check should pass

    result = check_trim_compat(TrimBadImpl)
    @test !result.passed
    @test !isempty(result.issues)
    # The issue should mention Base.return_types
    issue_text = join(Iterators.flatten(values(result.issues)), " ")
    @test occursin("return_types", issue_text)
end

@testitem "@verify trim_compat=true — no-op when methods are clean" setup = [TCFixtures] begin
    using Test
    using TypeContracts
    using .TCFixtures

    # Should not warn and should not throw.
    abstract type AbstractVerifyClean end
    function vclean_fn end
    @contract AbstractVerifyClean begin
        vclean_fn(::Self)::Int
    end
    struct VCleanImpl <: AbstractVerifyClean end
    vclean_fn(::VCleanImpl)::Int = 42

    # @verify with trim_compat=true runs check_trim_compat; result should be clean.
    result = check_trim_compat(VCleanImpl)
    @test result.passed
    @test isempty(result.issues)

    # The macro itself must not throw.
    @test (@verify VCleanImpl trim_compat = true; true)
end
