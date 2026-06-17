# ── TrimDiagnostics: translate juliac --trim verifier output ──────────────────
#
# Self-contained submodule (no other TypeContracts module depends on it) so it can be
# split into a standalone package later. It turns juliac's verbose, repetitive
# `--trim=safe` verifier output into a concise, source-mapped, actionable error.
#
# juliac (Julia 1.12) emits, per rejected call, a block of the form:
#
#     Verifier error #N: unresolved call from statement <statement>
#     Stacktrace:
#      [1] func(argtypes)
#        @ Module /path/to/file.jl:LINE
#      [2] ...
#
# blocks separated by blank lines. The same root cause is usually reported several
# times (the call and its `convert`), so we group by source location.
module TrimDiagnostics

export TrimFailure, explain_trim_failure

"""
    TrimFrame(func, file, line)

One stack frame from a juliac verifier error: the (textual) called function with its
argument types, the source file, and the line.
"""
struct TrimFrame
    func::String
    file::String
    line::Int
end

"""
    TrimSite(reason, statement, frames, count)

One grouped trim-verifier finding: the verifier `reason`, the offending `statement`
(the IR statement juliac could not resolve), the call `frames` (innermost first), and
`count` raw verifier errors that collapsed into this site (same source location).
"""
struct TrimSite
    reason::String
    statement::String
    frames::Vector{TrimFrame}
    count::Int
end

"""
    TrimFailure(sites, raw; recognized, entry_path, source_files)

A parsed `juliac --trim` failure. `sites` are the deduplicated findings; `raw` is the
original verifier output; `recognized` is `false` when the output did not match the
known format (then `showerror` falls back to a trimmed raw dump so nothing is hidden).
`entry_path`/`source_files` identify generated vs. user code for frame selection.
"""
struct TrimFailure <: Exception
    sites::Vector{TrimSite}
    raw::String
    recognized::Bool
    entry_path::String
    source_files::Vector{String}
end

const _HEADER_RE = r"^Verifier error #(\d+):\s*(.*)$"
const _FRAME_CALL_RE = r"^\s*\[\d+\]\s+(.+?)\s*$"
const _FRAME_LOC_RE  = r"^\s*@\s+(\S+)\s+(.*):(\d+)\s*$"
const _STMT_PREFIX = "unresolved call from statement "

# Extract the offending IR statement from a verifier reason, when present.
function _statement_of(reason::AbstractString)
    startswith(reason, _STMT_PREFIX) ? String(reason[length(_STMT_PREFIX)+1:end]) :
        String(reason)
end

# Parse the raw verifier output into ungrouped (reason, frames) findings.
function _parse_blocks(output::AbstractString)
    findings = Tuple{String,Vector{TrimFrame}}[]
    lines = split(output, '\n')
    i = 1
    n = length(lines)
    while i <= n
        m = match(_HEADER_RE, lines[i])
        if m === nothing
            i += 1
            continue
        end
        reason = String(m.captures[2])
        i += 1
        frames = TrimFrame[]
        # Consume the stacktrace until a blank line / next header / non-frame line.
        while i <= n
            line = lines[i]
            (isempty(strip(line)) || startswith(strip(line), "Verifier error #") ||
             startswith(strip(line), "ERROR:")) && break
            cm = match(_FRAME_CALL_RE, line)
            if cm !== nothing && i + 1 <= n
                lm = match(_FRAME_LOC_RE, lines[i+1])
                if lm !== nothing
                    push!(frames, TrimFrame(String(cm.captures[1]),
                                            String(lm.captures[2]),
                                            parse(Int, lm.captures[3])))
                    i += 2
                    continue
                end
            end
            i += 1
        end
        push!(findings, (reason, frames))
    end
    return findings
end

# True for a frame that is the user's own code (not the generated juliac entry).
function _is_user_frame(f::TrimFrame, entry_path::AbstractString,
                        source_files::AbstractVector{<:AbstractString})
    isempty(f.file) && return false
    bn = basename(f.file)
    bn == "_pt_entry.jl" && return false                  # ParselTongue entry
    !isempty(entry_path) && f.file == entry_path && return false
    isempty(source_files) && return true
    any(s -> f.file == s || basename(s) == bn, source_files)
end

# The innermost user frame, or the innermost frame of any kind as a fallback.
function _primary_frame(frames, entry_path, source_files)
    isempty(frames) && return nothing
    for f in frames
        _is_user_frame(f, entry_path, source_files) && return f
    end
    return first(frames)
end

# Group findings that share a source location (file:line) into one site.
function _group(findings, entry_path, source_files)
    order = String[]
    by_key = Dict{String,Tuple{String,Vector{TrimFrame},Int}}()
    for (reason, frames) in findings
        pf = _primary_frame(frames, entry_path, source_files)
        key = pf === nothing ? reason : string(pf.file, ":", pf.line, ":", pf.func)
        if haskey(by_key, key)
            r, fr, c = by_key[key]
            by_key[key] = (r, fr, c + 1)
        else
            push!(order, key)
            by_key[key] = (reason, frames, 1)
        end
    end
    [TrimSite(by_key[k][1], _statement_of(by_key[k][1]), by_key[k][2], by_key[k][3])
     for k in order]
end

"""
    explain_trim_failure(output; entry_path="", source_files=String[]) -> TrimFailure

Parse `juliac --trim` verifier output into a [`TrimFailure`](@ref) with a readable,
source-mapped `showerror`. `entry_path` and `source_files` let the parser map findings
to the user's own code (vs. generated wrappers). If the output is not in the recognised
verifier format, the result still carries `raw` and renders a trimmed dump.
"""
function explain_trim_failure(output::AbstractString; entry_path::AbstractString="",
                              source_files=String[])
    sfiles = collect(String, source_files)
    local sites::Vector{TrimSite}
    try
        sites = _group(_parse_blocks(output), entry_path, sfiles)
    catch
        sites = TrimSite[]
    end
    TrimFailure(sites, String(output), !isempty(sites), String(entry_path), sfiles)
end

# A short, actionable hint for one site, keyed off the statement text.
function _hint(s::TrimSite)
    stmt = s.statement
    if occursin("::Any", stmt)
        return "a value inferred as `Any` makes this call dynamic — annotate or " *
               "narrow the type (e.g. `x::Concrete`, a type assertion, or avoid " *
               "abstract containers) so the call is statically resolvable."
    elseif occursin("return_types", stmt) || occursin("invokelatest", stmt) ||
           occursin(".which", stmt) || occursin(".methods", stmt)
        return "this is reflection/runtime dispatch (`return_types`/`invokelatest`/" *
               "`which`/`methods`) — `--trim=safe` forbids it; compute it at build time."
    end
    return "`--trim=safe` needs every call statically resolvable; this one is a dynamic " *
           "dispatch. Make the argument/return types concrete, or split out the dynamic part."
end

const _MAX_SITES = 12

function Base.showerror(io::IO, e::TrimFailure)
    printstyled(io, "TrimFailure"; bold = true, color = :red)
    if !e.recognized
        print(io, ": juliac --trim failed (unrecognised verifier output).\n")
        raw = strip(e.raw)
        tail = length(raw) > 2000 ? "…\n" * raw[max(1, end-2000):end] : raw
        printstyled(io, tail; color = :light_black)
        return
    end
    nsite = length(e.sites)
    total = sum(s.count for s in e.sites; init = 0)
    print(io, ": juliac --trim=safe rejected ")
    printstyled(io, nsite, nsite == 1 ? " call site" : " call sites"; bold = true)
    total > nsite && print(io, " ($(total) verifier errors)")
    println(io, " — these calls are not statically resolvable.\n")
    for (idx, s) in enumerate(e.sites)
        idx > _MAX_SITES && (printstyled(io, "  … and $(nsite - _MAX_SITES) more site(s).\n"; color = :light_black); break)
        pf = _primary_frame(s.frames, e.entry_path, e.source_files)
        printstyled(io, "  ✗ "; color = :red)
        if pf !== nothing
            printstyled(io, pf.func; color = :cyan, bold = true)
            printstyled(io, "  ", basename(pf.file), ":", pf.line; color = :light_black)
            s.count > 1 && printstyled(io, "  ($(s.count) errors)"; color = :light_black)
        else
            print(io, s.reason)
        end
        println(io)
        if !isempty(s.statement)
            print(io, "      unresolved: ")
            printstyled(io, s.statement; color = :yellow)
            println(io)
        end
        printstyled(io, "      → ", _hint(s); color = :green)
        println(io)
    end
    printstyled(io, "\n  (rebuild with verbose=true / keep_build=true for raw juliac output.)";
                color = :light_black)
    return
end

end # module TrimDiagnostics
