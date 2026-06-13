module TypeContractsReviseExt

using TypeContracts
using Revise

function _after_revise()
    for mod in TypeContracts._revise_tracked_modules
        TypeContracts._revise_check_module(mod)
    end
    for T in TypeContracts._revise_tracked_types
        TypeContracts._check_contract_warn(T)
    end
    return
end

function __init__()
    return Revise.add_callback(_after_revise, String[]; all = true)
end

end
