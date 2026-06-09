@testitem "juliac compatibility" setup = [TCFixtures] begin
    using Test
    using TypeContracts
    using .TCFixtures
    using InteractiveUtils: code_warntype

    @testset "runtime path interface_trait is doc-free" begin
        @test interface_trait(AbstractRT, RTGood) isa Implemented{AbstractRT}
        @test interface_trait(AbstractRT, RTBad) isa NotImplemented{AbstractRT}

        io = IOBuffer()
        code_warntype(io, TypeContracts.interface_trait, Tuple{Type{AbstractRT}, Type{RTGood}})
        s = String(take!(io))
        @test !occursin("Markdown", s)
        @test !occursin("_attach_contract_doc", s)
    end

    @testset "extension is absent in script mode (no-op hook)" begin
        @test !isempty(registered_contracts())
    end
end
