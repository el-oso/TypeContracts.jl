module ShapesExample
using TypeContracts

# ── Interface declaration ─────────────────────────────────────────────

abstract type AbstractShape end

function area end
function perimeter end
function translate end
function shape_name end
function shape_color end

# area and perimeter are mandatory with declared return types.
# shape_name and shape_color are optional.
@contract AbstractShape begin
    area(::Self)::Float64
    perimeter(::Self)::Float64
    translate(::Self, ::Float64, ::Float64)::AbstractShape
    :optional
    shape_name(::Self)::String
    shape_color(::Self)::Symbol
end

@invariants AbstractShape begin
    "area is non-negative" => x -> area(x) >= 0
    "perimeter is non-negative" => x -> perimeter(x) >= 0
    :optional
    "name is non-empty" => x -> !isempty(shape_name(x))
end

# ── Conforming types ──────────────────────────────────────────────────

struct Circle <: AbstractShape
    x::Float64
    y::Float64
    radius::Float64
end

area(c::Circle)::Float64 = π * c.radius^2
perimeter(c::Circle)::Float64 = 2π * c.radius
translate(c::Circle, dx::Float64, dy::Float64)::AbstractShape =
    Circle(c.x + dx, c.y + dy, c.radius)
shape_name(::Circle) = "circle"

@verify Circle

struct Rectangle <: AbstractShape
    x::Float64
    y::Float64
    w::Float64
    h::Float64
end

area(r::Rectangle)::Float64 = r.w * r.h
perimeter(r::Rectangle)::Float64 = 2(r.w + r.h)
translate(r::Rectangle, dx::Float64, dy::Float64)::AbstractShape =
    Rectangle(r.x + dx, r.y + dy, r.w, r.h)

# shape_name and shape_color not implemented — optional, so @verify still passes.
@verify Rectangle

# ── Holy trait dispatch ───────────────────────────────────────────────

# Dispatch on whether a type satisfies the AbstractShape contract.
_render(::Implemented{AbstractShape}, x) = "Shape[area=$(round(area(x); digits = 2))]"
_render(::NotImplemented{AbstractShape}, x) = "NotAShape[$(typeof(x))]"
render(x) = _render(interface_trait(AbstractShape, typeof(x)), x)

# render(Circle(0,0,3))  → "Shape[area=28.27]"
# render(42)             → "NotAShape[Int64]"

# ── Return type enforcement ───────────────────────────────────────────

# A type whose area() returns the wrong type fails @verify.
# Uncomment to see the InterfaceError at load time:
#
#   struct BadShape <: AbstractShape; r::Float64 end
#   area(b::BadShape)      = "oops"             # String, not Float64
#   perimeter(b::BadShape) = 2π * b.r
#   translate(b::BadShape, dx::Float64, dy::Float64)::AbstractShape = b
#   @verify BadShape   # → InterfaceError: return String ⊄ Float64

# satisfies() gives a non-throwing report:
#
#   satisfies(BadShape, AbstractShape)
#   # missing_methods = ["area(::Self) :: Float64 [return: String ⊄ Float64]"]

# ── Parametric interface ──────────────────────────────────────────────

abstract type AbstractContainer{T} end

function cget end
function cset! end
function clen end

# T resolves to the element type of the concrete subtype at check time.
@contract AbstractContainer{T} begin
    cget(::Self, ::Int)::T
    cset!(::Self, ::T, ::Int)
    clen(::Self)::Int
end

struct FloatBox <: AbstractContainer{Float64}
    data::Vector{Float64}
end

cget(b::FloatBox, i::Int)::Float64 = b.data[i]
cset!(b::FloatBox, v::Float64, i::Int) = (b.data[i] = v)
clen(b::FloatBox)::Int = length(b.data)

@verify FloatBox   # T = Float64; inferred return type of cget matches

# ── Supertype chain ───────────────────────────────────────────────────

# Contracts propagate down the type hierarchy automatically.
# A concrete type must satisfy the union of contracts from all its abstract supertypes.
#
#   describe(FloatBox, Val(:all))
#   # From AbstractContainer:
#   #   cget(::Self, ::Int) :: T
#   #   cset!(::Self, ::T, ::Int)
#   #   clen(::Self) :: Int

# ── Bulk enforcement ──────────────────────────────────────────────────

# @verify_all checks every concrete subtype defined in this module.
# Place it at the end after all type and method definitions.
@verify_all

end # module ShapesExample
