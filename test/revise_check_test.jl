@testitem "Revise re-check warns on every failure" begin
    using Test
    using TypeContracts

    @contract ReviseShape begin
        revise_area(::Self)::Float64
    end
    struct ReviseBadShape <: ReviseShape end

    @test_logs (:warn, "Contract violation detected by Revise") match_mode = :any TypeContracts._check_contract_warn(ReviseBadShape)

    # `check_contract(Union{})` throws a MethodError rather than an InterfaceError.
    @test_logs (:warn, "Contract re-check failed") match_mode = :any TypeContracts._check_contract_warn(Union{})
end
