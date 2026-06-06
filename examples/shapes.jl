# ══════════════════════════════════════════════════════════════════════
# TypeContracts.jl — Full Example
#
# Demonstrates all features:
#   1. Discoverability         — query what an abstract type requires
#   2. Test-time checking      — verify implementations in tests
#   3. Compile-time enforcement — @verify blocks precompilation
#   4. Retroactive contracts   — add contracts to types you don't own
#   5. Optional methods        — methods a type may skip
#   6. Holy trait dispatch      — dispatch on interface satisfaction
#   7. Behavioral invariants   — test correctness, not just existence
#   8. describe()              — pretty-print full contract
# ══════════════════════════════════════════════════════════════════════

# Run from the TypeContracts package directory:
#   julia --project=. examples/shapes.jl

using TypeContracts

# ── Declare interface functions ───────────────────────────────────────

function area end
function perimeter end
function translate end
function shape_name end
function shape_color end

# ── Define the contract with optional methods ─────────────────────────

abstract type AbstractShape end

@contract AbstractShape begin
    area(::Self) :: Float64
    perimeter(::Self) :: Float64
    translate(::Self, dx::Float64, dy::Float64) :: AbstractShape
    :optional
    shape_name(::Self) :: String
    shape_color(::Self) :: Symbol
end

@invariants AbstractShape begin
    "area is non-negative" => x -> area(x) >= 0
    "perimeter is non-negative" => x -> perimeter(x) >= 0
    :optional
    "name is non-empty" => x -> !isempty(shape_name(x))
end

# ── describe() — full contract view ───────────────────────────────────

println("=" ^ 60)
println("DESCRIBE: Full contract view")
println("=" ^ 60)
println()
describe(AbstractShape)
println()

# ── Implement conforming types ────────────────────────────────────────

struct Circle <: AbstractShape
    x::Float64
    y::Float64
    radius::Float64
end

area(c::Circle) = π * c.radius^2
perimeter(c::Circle) = 2π * c.radius
translate(c::Circle, dx::Float64, dy::Float64) = Circle(c.x + dx, c.y + dy, c.radius)
shape_name(::Circle) = "circle"

@verify Circle

struct Rectangle <: AbstractShape
    x::Float64
    y::Float64
    w::Float64
    h::Float64
end

area(r::Rectangle) = r.w * r.h
perimeter(r::Rectangle) = 2(r.w + r.h)
translate(r::Rectangle, dx::Float64, dy::Float64) = Rectangle(r.x + dx, r.y + dy, r.w, r.h)

@verify Rectangle

println("=" ^ 60)
println("COMPILE-TIME: @verify at load time")
println("=" ^ 60)
println()
println("@verify Circle    — passed (implements all mandatory + shape_name optional)")
println("@verify Rectangle — passed (implements all mandatory, skips optional)")
println()

# ── satisfies() — mandatory vs optional ───────────────────────────────

println("=" ^ 60)
println("OPTIONAL METHODS: satisfies() detail")
println("=" ^ 60)
println()

for T in [Circle, Rectangle]
    result = satisfies(T, AbstractShape)
    println("satisfies($T, AbstractShape)")
    println("  satisfied       = $(result.satisfied)")
    println("  missing_methods  = $(result.missing_methods)")
    println("  missing_optional = $(result.missing_optional)")
    println()
end

# ── Holy trait dispatch ───────────────────────────────────────────────

println("=" ^ 60)
println("HOLY TRAIT DISPATCH")
println("=" ^ 60)
println()

_render(::Implemented{AbstractShape}, x)    = "Shape[$(shape_name(x)), area=$(round(area(x); digits=2))]"
_render(::NotImplemented{AbstractShape}, x) = "NotAShape[$(typeof(x))]"
render(x) = _render(interface_trait(AbstractShape, typeof(x)), x)

# Circle has shape_name → full render
println("render(Circle(0,0,3))       = ", render(Circle(0, 0, 3)))
# Int doesn't satisfy AbstractShape → fallback
println("render(42)                  = ", render(42))
println()

# Rectangle doesn't have shape_name — but trait still works because
# it checks mandatory methods only. The render function would error
# on shape_name call though, so let's use a safer dispatch:
_render_safe(::Implemented{AbstractShape}, x)    = "Shape[area=$(round(area(x); digits=2))]"
_render_safe(::NotImplemented{AbstractShape}, x) = "NotAShape"
render_safe(x) = _render_safe(interface_trait(AbstractShape, typeof(x)), x)

println("render_safe(Rectangle(...)) = ", render_safe(Rectangle(0, 0, 4, 5)))
println("render_safe(\"hello\")        = ", render_safe("hello"))
println()

# ── Behavioral testing ────────────────────────────────────────────────

println("=" ^ 60)
println("BEHAVIORAL TESTING")
println("=" ^ 60)
println()

test_objects = [Circle(0, 0, 1), Circle(0, 0, 5), Circle(1, 2, 0.5)]
result = test_behavior(Circle, AbstractShape, test_objects)
println("test_behavior(Circle, AbstractShape, [3 circles])")
println("  passed = $(result.passed)")
println("  total checks = $(length(result.results))")
println()

# Triangle with negative area via bad vertex ordering
struct Triangle <: AbstractShape
    x1::Float64; y1::Float64
    x2::Float64; y2::Float64
    x3::Float64; y3::Float64
end

area(t::Triangle) = (t.x1*(t.y2-t.y3) + t.x2*(t.y3-t.y1) + t.x3*(t.y1-t.y2)) / 2
perimeter(t::Triangle) = begin
    d(ax,ay,bx,by) = sqrt((ax-bx)^2 + (ay-by)^2)
    d(t.x1,t.y1,t.x2,t.y2) + d(t.x2,t.y2,t.x3,t.y3) + d(t.x3,t.y3,t.x1,t.y1)
end
translate(t::Triangle, dx::Float64, dy::Float64) = Triangle(t.x1+dx,t.y1+dy,t.x2+dx,t.y2+dy,t.x3+dx,t.y3+dy)

# This triangle has negative area (wrong vertex winding)
bad_tri = Triangle(0, 0, 0, 1, 1, 0)
result = test_behavior(Triangle, AbstractShape, [bad_tri])
println("test_behavior(Triangle, AbstractShape, [bad winding])")
println("  passed = $(result.passed)")
if !result.passed
    println("  failures:")
    for f in result.mandatory_failures
        println("    - $(f.description)")
    end
end
println()

# ── Retroactive contracts ────────────────────────────────────────────

println("=" ^ 60)
println("RETROACTIVE CONTRACTS")
println("=" ^ 60)
println()

@contract AbstractString begin
    length(::Self)
    ncodeunits(::Self)
    isvalid(::Self)
end

println("Contract for AbstractString (from Base):")
for spec in list_contract(AbstractString)
    println("  ", spec)
end
println()
println("String satisfies it? ", satisfies(String, AbstractString).satisfied)
println()

# ── Full supertype chain view ─────────────────────────────────────────

println("=" ^ 60)
println("DESCRIBE: Full supertype chain")
println("=" ^ 60)
println()

abstract type AbstractDrawable end
abstract type AbstractResizableDrawable <: AbstractDrawable end

function draw end
function resize end

@contract AbstractDrawable begin
    draw(::Self) :: String
end

@contract AbstractResizableDrawable begin
    resize(::Self, ::Float64) :: AbstractResizableDrawable
end

@invariants AbstractDrawable begin
    "draw returns non-empty string" => x -> !isempty(draw(x))
end

struct Icon <: AbstractResizableDrawable
    name::String
    scale::Float64
end

draw(i::Icon) = "icon:$(i.name)@$(i.scale)x"
resize(i::Icon, factor::Float64) = Icon(i.name, i.scale * factor)

@verify Icon

describe(Icon, Val(:all))
println()
println("=" ^ 60)
println("All checks passed.")
println("=" ^ 60)
