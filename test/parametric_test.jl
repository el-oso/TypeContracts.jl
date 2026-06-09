@testitem "Parametric contracts" setup = [TCFixtures] begin
    using Test
    using TypeContracts
    using .TCFixtures

    @testset "_extract_param resolves type parameters" begin
        ref_T = TypeParamRef(AbstractArray, 1)
        ref_N = TypeParamRef(AbstractArray, 2)

        @test TypeContracts._extract_param(Vector{Float64}, ref_T) == Float64
        @test TypeContracts._extract_param(Vector{Float64}, ref_N) == 1
        @test TypeContracts._extract_param(Matrix{Int}, ref_T) == Int
        @test TypeContracts._extract_param(Matrix{Int}, ref_N) == 2
    end

    @testset "_extract_param returns Any for unrelated type" begin
        ref = TypeParamRef(AbstractArray, 1)
        @test TypeContracts._extract_param(String, ref) === Any
    end

    @testset "conforming parametric type passes" begin
        @test check_contract(IntBucket).passed
    end

    @testset "wrong element return type is caught" begin
        err = try
            check_contract(WrongBucket); nothing
        catch e
            e
        end
        @test err isa InterfaceError
        @test occursin("bget", err.msg)
    end

    @testset "TypeParamRef stored in arg_types" begin
        specs = list_contract(AbstractBucket)
        bset_spec = first(filter(s -> occursin("bset!", s.description), specs))
        @test bset_spec.arg_types[2] isa TypeParamRef
        @test bset_spec.arg_types[2].param_index == 1
    end

    @testset "TypeParamRef stored in return_type_spec" begin
        specs = list_contract(AbstractBucket)
        bget_spec = first(filter(s -> occursin("bget", s.description), specs))
        @test bget_spec.return_type_spec isa TypeParamRef
        @test bget_spec.return_type_spec.param_index == 1
        @test bget_spec.return_type == Any
    end

    @testset "description shows type variable symbol" begin
        specs = list_contract(AbstractBucket)
        bget_spec = first(filter(s -> occursin("bget", s.description), specs))
        @test occursin("T", bget_spec.description)
    end

    @testset "non-parametric contract header still works" begin
        specs = list_contract(AbstractShape)
        @test length(specs) == 4
        @test all(s -> !(s.return_type_spec isa TypeParamRef), specs)
    end

    @testset "@verify_all on parametric type" begin
        threw = try
            @eval module VerifyParamFail
            using TypeContracts

            abstract type AbstractStack{T} end
            function spush! end
            function spop! end

            @contract AbstractStack{T} begin
                spush!(::Self, ::T)
                spop!(::Self)::T
            end

            struct IntStack <: AbstractStack{Int}
                data::Vector{Int}
            end
            spush!(s::IntStack, v::Int) = push!(s.data, v)
            spop!(s::IntStack)::String = "oops"  # wrong return type

            @verify_all
            end
            false
        catch
            true
        end
        @test threw
    end
end
