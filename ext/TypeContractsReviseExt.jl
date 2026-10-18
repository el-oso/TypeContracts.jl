module TypeContractsReviseExt

using TypeContracts
using Revise

function _after_revise()
    for mod in TypeContracts._revise_tracked_modules
        TypeContracts._revise_check_module(mod)
    end
    for (mod, T, I) in TypeContracts._revise_tracked_types
        TypeContracts._check_contract_warn(mod, T, I)
    end
    return
end

function __init__()
    return Revise.add_callback(_after_revise, String[]; all = true)
end

end
