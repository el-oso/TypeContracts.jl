@testitem "Documentation integration" setup = [TCFixtures] begin
    using Test
    using TypeContracts
    using .TCFixtures
    import REPL  # needed in this module's scope for Core.eval(@__MODULE__, REPL.helpmode(...))

    "Prior docstring for AbstractGizmo."
    abstract type AbstractGizmo end
    function gizmo_spin end
    function gizmo_label end

    @contract AbstractGizmo "A spinnable gizmo." begin
        gizmo_spin(::Self)::Int => "revolutions per spin"
        :optional
        gizmo_label(::Self)::String => "display label"
    end

    @testset "per-method docs stored on MethodSpec" begin
        specs = list_contract(AbstractGizmo)
        spin = first(filter(s -> occursin("gizmo_spin", s.description), specs))
        @test spin.doc == "revolutions per spin"
        label = first(filter(s -> occursin("gizmo_label", s.description), specs))
        @test label.doc == "display label"
    end

    @testset "interface description stored" begin
        @test TypeContracts._contract_desc(AbstractGizmo) == "A spinnable gizmo."
    end

    @testset "describe surfaces prose" begin
        buf = IOBuffer()
        describe(AbstractGizmo; io = buf)
        out = String(take!(buf))
        @test occursin("A spinnable gizmo.", out)
        @test occursin("revolutions per spin", out)
        @test occursin("display label", out)
    end

    @testset "contract with no descriptions still works" begin
        abstract type AbstractPlain end
        function plain_fn end
        @contract AbstractPlain begin
            plain_fn(::Self)
        end
        specs = list_contract(AbstractPlain)
        @test specs[1].doc == ""
        @test TypeContracts._contract_desc(AbstractPlain) == ""
    end

    @testset "non-string method description is rejected" begin
        @test_throws LoadError @eval @contract AbstractGizmo begin
            gizmo_spin(::Self) => 42
        end
    end

    @testset "?-doc renders contract section for owned type" begin
        help_md = Core.eval(@__MODULE__, REPL.helpmode(IOBuffer(), "AbstractGizmo", @__MODULE__))
        rendered = sprint(show, MIME("text/plain"), help_md)
        @test occursin("TypeContracts Interface", rendered)
        @test occursin("A spinnable gizmo.", rendered)
        @test occursin("revolutions per spin", rendered)
        @test occursin("Mandatory methods", rendered)
        @test occursin("Optional methods", rendered)
    end

    @testset "?-doc preserves the prior docstring (coexists)" begin
        help_md = Core.eval(@__MODULE__, REPL.helpmode(IOBuffer(), "AbstractGizmo", @__MODULE__))
        rendered = sprint(show, MIME("text/plain"), help_md)
        @test occursin("Prior docstring for AbstractGizmo.", rendered)
        @test occursin("TypeContracts Interface", rendered)
    end

    @testset "retroactive contract documents a foreign Base type" begin
        @contract AbstractRange "A range contract (retroactive)." begin
            first(::Self) => "first element"
            last(::Self) => "last element"
        end
        help_md = Core.eval(@__MODULE__, REPL.helpmode(IOBuffer(), "AbstractRange"))
        rendered = sprint(show, MIME("text/plain"), help_md)
        @test occursin("Supertype for ranges", rendered) || occursin("AbstractRange", rendered)
        @test occursin("A range contract (retroactive).", rendered)
        @test occursin("first element", rendered)
    end

    @testset "invariants refresh the doc" begin
        abstract type AbstractWheel end
        function wheel_radius end
        @contract AbstractWheel "A wheel." begin
            wheel_radius(::Self)::Float64 => "radius in metres"
        end
        @invariants AbstractWheel begin
            "radius is positive" => x -> wheel_radius(x) > 0
        end
        help_md = Core.eval(@__MODULE__, REPL.helpmode(IOBuffer(), "AbstractWheel", @__MODULE__))
        rendered = sprint(show, MIME("text/plain"), help_md)
        @test occursin("radius in metres", rendered)
        @test occursin("radius is positive", rendered)
    end

    @testset "re-registration does not warn (clears prior entry)" begin
        @test_nowarn TypeContracts._attach_contract_doc(AbstractRepeat)
        @test_nowarn TypeContracts._attach_contract_doc(AbstractRepeat)
    end
end
