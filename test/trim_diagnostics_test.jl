@testitem "trim_report — proactive dynamic-dispatch scan" begin
    using TypeContracts
    using Test

    # A concrete, fully-resolvable function passes.
    tr_good(x::Int64) = x + 1
    rg = trim_report(tr_good, Tuple{Int64})
    @test rg.passed
    @test isempty(rg.findings)
    @test occursin("no obvious trim-unsafe", sprint(showerror, rg))

    # A function with a dynamic dispatch (inferencebarrier → Any) is flagged.
    tr_dyn(n::Int64) = Base.inferencebarrier(n) + 1
    rd = trim_report(tr_dyn, Tuple{Int64})
    @test !rd.passed
    @test !isempty(rd.findings)
    msg = sprint(showerror, rd)
    @test occursin("trim-unsafe", msg)
    @test occursin("Any", msg)

    # Reflection callee is flagged too.
    tr_refl() = Base.return_types(+, Tuple{Int,Int})
    rr = trim_report(tr_refl, Tuple{})
    @test !rr.passed
    @test any(f -> occursin("return_types", f), rr.findings)
end

@testitem "explain_trim_failure — reactive juliac output translation" begin
    using TypeContracts
    using Test

    # Real juliac 1.12 --trim=safe verifier format: same root cause reported as the
    # call AND its convert, each at the same user source location (should collapse).
    sample = """
    Verifier error #1: unresolved call from statement (Base.compilerbarrier(:type, n::Int64)::Any + 1)::Any
    Stacktrace:
     [1] dyn(n::Int64)
       @ Main /tmp/badtrim.jl:6
     [2] pt_dyn(n::Int64, _pt_err::Ptr{Int32}, _pt_errmsg::Ptr{Ptr{UInt8}})
       @ Main /tmp/x/_pt_entry.jl:8

    Verifier error #2: unresolved call from statement Base.convert(Main.Int64, (Base.compilerbarrier(:type, n::Int64)::Any + 1)::Any)::Any
    Stacktrace:
     [1] dyn(n::Int64)
       @ Main /tmp/badtrim.jl:6
     [2] pt_dyn(n::Int64, _pt_err::Ptr{Int32}, _pt_errmsg::Ptr{Ptr{UInt8}})
       @ Main /tmp/x/_pt_entry.jl:8
    """
    f = explain_trim_failure(sample; entry_path = "/tmp/x/_pt_entry.jl",
                             source_files = ["/tmp/badtrim.jl"])
    @test f isa TrimFailure
    @test f.recognized
    @test length(f.sites) == 1            # grouped by user source location
    @test f.sites[1].count == 2           # two raw verifier errors collapsed
    msg = sprint(showerror, f)
    @test occursin("rejected", msg)
    @test occursin("dyn(n::Int64)", msg)  # the user frame, not the generated wrapper
    @test occursin("badtrim.jl:6", msg)
    @test occursin("compilerbarrier", msg)  # offending statement surfaced
    @test !occursin("_pt_entry.jl", msg)    # generated frame filtered out

    # Unrecognised output degrades gracefully (keeps raw, never hides info).
    bad = explain_trim_failure("some unrelated compiler noise\nwith no verifier blocks")
    @test !bad.recognized
    bmsg = sprint(showerror, bad)
    @test occursin("unrecognised", bmsg)
    @test occursin("unrelated compiler noise", bmsg)
end

@testitem "explain_trim_failure — multiple distinct sites" begin
    using TypeContracts
    using Test

    # Two errors at two different source locations must NOT collapse.
    two_sites = """
Verifier error #1: unresolved call from statement (Base.compilerbarrier(:type, x::Int64)::Any + 1)::Any
Stacktrace:
 [1] foo(x::Int64)
   @ Main /tmp/file_a.jl:10
 [2] pt_foo(x::Int64, _pt_err::Ptr{Int32}, _pt_errmsg::Ptr{Ptr{UInt8}})
   @ Main /tmp/x/_pt_entry.jl:8

Verifier error #2: unresolved call from statement (Base.compilerbarrier(:type, y::Int64)::Any - 1)::Any
Stacktrace:
 [1] bar(y::Int64)
   @ Main /tmp/file_b.jl:20
 [2] pt_bar(y::Int64, _pt_err::Ptr{Int32}, _pt_errmsg::Ptr{Ptr{UInt8}})
   @ Main /tmp/x/_pt_entry.jl:12
"""
    f = explain_trim_failure(two_sites;
                             entry_path = "/tmp/x/_pt_entry.jl",
                             source_files = ["/tmp/file_a.jl", "/tmp/file_b.jl"])
    @test f.recognized
    @test length(f.sites) == 2
    msg = sprint(showerror, f)
    @test occursin("foo(x::Int64)", msg)
    @test occursin("bar(y::Int64)", msg)
    @test occursin("file_a.jl:10", msg)
    @test occursin("file_b.jl:20", msg)
end

@testitem "trim scan — :invoke static call to trim-unsafe callee" begin
    using TypeContracts
    using Test

    # A synthetic :invoke whose direct argument is Base.return_types exercises the
    # :invoke branch of _scan_trim_stmt! (static dispatch to a trim-unsafe callee,
    # as emitted by the optimizer when the call site is monomorphic).
    issues = String[]
    TypeContracts._scan_trim_stmt!(
        issues,
        Expr(:invoke, nothing, Base.return_types, +, Tuple{Int, Int}),
    )
    @test !isempty(issues)
    @test any(s -> occursin("static call", s), issues)
    @test any(s -> occursin("return_types", s), issues)
end
