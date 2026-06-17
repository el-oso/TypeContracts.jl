module TypeContracts

using InteractiveUtils: supertypes, subtypes

include("types.jl")
export Self, TypeParamRef, InterfaceError, MethodSpec, BehaviorSpec,
    Implemented, NotImplemented

include("registry.jl")
export registered_contracts, registered_behaviors

include("check.jl")
export check_contract, satisfies, implements, list_contract, list_behaviors

include("trim.jl")
export check_trim_compat, trim_report, TrimReport

# Reactive juliac --trim output translation. Kept in its own submodule (no other
# module depends on it) so it can be extracted into a standalone package later.
include("trim_diagnostics.jl")
using .TrimDiagnostics: TrimDiagnostics, TrimFailure, explain_trim_failure
export TrimDiagnostics, TrimFailure, explain_trim_failure

include("trait.jl")
export interface_trait

include("behavior.jl")
export test_behavior, behavior_passes, @test_implements, @test_behavior_passes

include("describe.jl")
export describe, contract_md_string, contract_md

include("macros.jl")
export @contract, @verify, @verify_all, @invariants, @delegate

end # module TypeContracts
