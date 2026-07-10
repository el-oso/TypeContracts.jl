# Julia + TypeContracts vs Rust vs Go

Three languages, three interface philosophies.

**Go** uses implicit structural typing — a type satisfies an interface by having the right
methods, no declaration needed; struct embedding auto-forwards entire interfaces in one line.
**Rust** requires explicit `impl Trait for Type` with compile-time enforcement, default method
bodies, and a rich generic constraint system. **Julia + TypeContracts** layers machine-readable
contracts onto Julia's dynamic dispatch: violations are caught at module load time,
`interface_trait` gives `juliac --trim`-compatible static Holy Trait dispatch, and the
[Revise.jl](https://github.com/timholy/Revise.jl) extension re-checks conformance live after
each edit.

TC goes beyond both in three areas: **retroactive contracts** on foreign types without wrappers;
**behavioral invariants** attached directly to interfaces; and **live re-checking during
development** without recompiling.

---

## 1 · Default / Optional Method Behavior

Provide a fallback implementation that implementors can skip or override.

#### Julia + TypeContracts

```julia
@contract Animal "An entity that can vocalize." begin
    speak(::Self)    :: String => "primary vocalization"
    :optional
    label(::Self)    :: String => "human-readable label"
end
# Contract block shows optional status but NOT the fallback body.
# The fallback is a separate, structurally unlinked definition:
label(a::Animal) = string(typeof(a))
# — it could be here, in another file, or absent entirely.
# (Named `label`, not `describe`, to avoid shadowing TC's own exported
# `describe(T)` introspection function used below.)

struct Dog <: Animal end
speak(::Dog) = "woof"

@verify Dog    # passes — speak present, label optional

# TC advantage: optional/required distinction is machine-readable.
# satisfies(), describe(T), and ?-docs all surface it.
```

#### Rust

```rust
trait Animal {
    fn speak(&self) -> &str;

    // Default body — implementors may override
    fn label(&self) -> String {
        String::from(std::any::type_name::<Self>())
    }
}

struct Dog;
impl Animal for Dog {
    fn speak(&self) -> &str { "woof" }
    // label() uses the default body
}

// Missing speak (no impl Animal for a type)
// → compile error when the type is used as Animal
```

#### Go

```go
type Animal interface {
    Speak() string
    // Go interfaces cannot have default method bodies.
    // Optional or shared behavior needs a separate mechanism.
}

// Common pattern: an embedded base struct provides defaults.
type BaseAnimal struct{ Name string }
func (b BaseAnimal) Label() string { return b.Name }

type Dog struct{ BaseAnimal }
func (d Dog) Speak() string { return "woof" }

// Label is NOT part of the Animal interface —
// Go has no way to mark a method as optional within an
// interface and provide a default body for it.
```

!!! tip "Verdict — Rust wins on co-location; TC wins on queryability"
    Rust's default body is *inside* the trait definition: the signature, its optionality, and
    the default implementation are all visible in one read. The compiler type-checks the default
    body against `Self` — it is a verified artifact, not a free-floating definition.

    TC splits this across two places: `:optional` in the `@contract` block declares that a method
    is optional, but the fallback body is a separate `label(::Animal)` method that could be
    defined anywhere — or not at all — with no error or warning. TC has a real advantage in the
    other direction: the optional/required distinction is **machine-readable** via `satisfies()`,
    `describe(T)`, and `?`-docs. Rust has no type-level query for "which methods have defaults."

    Go has neither: no default bodies, no optional/required distinction — shared behavior lives
    in an embedded base struct, outside the interface contract and invisible to tooling.

---

## 2 · Interface / Type Hierarchies

Build capability levels where satisfying the child requires the parent.

#### Julia + TypeContracts

```julia
# The supertype chain must be declared first so each type can reference its parent.
# @contract auto-generates function stubs (area, perimeter, side_length):
abstract type Shape end
abstract type Polygon        <: Shape   end
abstract type RegularPolygon <: Polygon end

@contract Shape          begin; area(::Self)        :: Float64; end
@contract Polygon        begin; perimeter(::Self)   :: Float64; end
@contract RegularPolygon begin; side_length(::Self) :: Float64; end

struct Square <: RegularPolygon; side::Float64; end
area(s::Square)        = s.side^2
perimeter(s::Square)   = 4 * s.side
side_length(s::Square) = s.side

# Single call checks all three levels in the chain:
@verify Square

satisfies(Square, Shape)           # (satisfied = true, ...)
satisfies(Square, RegularPolygon)  # (satisfied = true, ...)
```

#### Rust

```rust
trait Shape    { fn area(&self) -> f64; }
trait Polygon: Shape    { fn perimeter(&self) -> f64; }
trait RegularPolygon: Polygon { fn side_length(&self) -> f64; }

struct Square { side: f64 }

impl Shape          for Square { fn area(&self) -> f64  { self.side.powi(2) } }
impl Polygon        for Square { fn perimeter(&self) -> f64 { 4.0 * self.side } }
impl RegularPolygon for Square { fn side_length(&self) -> f64 { self.side } }
// Missing any impl → compile error
```

#### Go

```go
type Shape interface { Area() float64 }
type Polygon interface {
    Shape               // interface embedding inherits Area
    Perimeter() float64
}
type RegularPolygon interface {
    Polygon             // inherits Area + Perimeter
    SideLength() float64
}

type Square struct{ Side float64 }
func (s Square) Area() float64       { return s.Side * s.Side }
func (s Square) Perimeter() float64  { return 4 * s.Side }
func (s Square) SideLength() float64 { return s.Side }

// Square satisfies all three interfaces implicitly.
var _ RegularPolygon = Square{}  // optional compile-time assertion
```

!!! tip "Verdict — three-way tie"
    All three express hierarchies naturally. Go interface embedding is the most concise. Rust
    requires a separate `impl` block per trait level. TC's single `@verify Square` walks the full
    supertype chain automatically, mirroring what Rust's supertrait system enforces but without
    the per-level boilerplate.

---

## 3 · Extending Foreign Types

Attach a formal contract to a type you don't own.

#### Julia + TypeContracts

```julia
using TypeContracts, BaseTypeContracts

# Contracts already registered for Base types:
implements(Vector{Int}, AbstractArray)      # true
implements(Dict{String,Int}, AbstractDict)  # true

# Retroactive contract on any abstract type you don't own — no wrapper
# or modification to the original package needed. A fresh interface name
# is used here rather than Base.AbstractSet, which BaseTypeContracts
# already contracts — registering over it would silently overwrite that
# package's contract (see "Contract coherence" in Key Differences).
@contract AbstractFiniteSet "A finite mathematical set." begin
    Base.intersect(::Self, ::Self) :: Self
    Base.union(::Self, ::Self)     :: Self
    Base.issubset(::Self, ::Self)  :: Bool
end

# Check whether any set type satisfies it:
satisfies(MyFancySet, AbstractFiniteSet)  # lists missing methods
```

#### Rust

```rust
// Orphan rule: you can implement a foreign trait for a
// foreign type only if at least one is defined in your crate.

// To formalize set operations you must define a new trait:
trait SetOps {
    fn intersect(&self, other: &Self) -> Self;
    fn union(&self, other: &Self)     -> Self;
    fn is_subset(&self, other: &Self) -> bool;
}

// Then implement it only for types in your crate:
impl SetOps for MySet { /* ... */ }

// Implementing SetOps for std::collections::HashSet is
// a compile error — both HashSet and SetOps are foreign.
// You must use a newtype wrapper.
```

#### Go

```go
// Go interfaces are satisfied implicitly — define a new
// interface and any type with matching methods satisfies it.
type SetLike interface {
    Intersect(other SetLike) SetLike
    Union(other SetLike)     SetLike
    IsSubset(other SetLike)  bool
}

// If a type already has these methods it satisfies SetLike —
// zero boilerplate for the consuming side.

// LIMIT: if the foreign type is missing a required method,
// you need a wrapper:
type WrappedSet struct{ inner somepackage.Set }
func (w WrappedSet) Intersect(o SetLike) SetLike { /* ... */ return w }
func (w WrappedSet) Union(o SetLike)     SetLike { /* ... */ return w }
func (w WrappedSet) IsSubset(o SetLike)  bool    { return true }
```

!!! tip "Verdict — TC advantage"
    TC attaches a formal, verifiable, documented contract to *any* abstract type — no wrapper,
    no modification to the original package. Go's implicit structural typing is ergonomic for
    types that already have the right methods, but requires a wrapper when methods are missing.
    Rust's orphan rule blocks `impl ForeignTrait for ForeignType` entirely.

---

## 4 · Type-Level Dispatch

Branch on whether a type satisfies an interface — statically, with zero runtime overhead.

#### Julia + TypeContracts

```julia
using TypeContracts, BaseTypeContracts

# interface_trait is @generated — arg types and function objects were
# baked in at macro-expansion time (no registry lookup); the generator
# runs at specialization time, emitting a static chain of hasmethod()
# calls. juliac --trim safe.
function process(x::T) where T
    _process(x, interface_trait(Iterable, T))
end
_process(x, ::Implemented{Iterable})    = collect(x)
_process(x, ::NotImplemented{Iterable}) = [x]

struct Point
    x::Float64
    y::Float64
end
# Point has no `iterate` method, so it genuinely does not implement Iterable
# (unlike numbers, which iterate as a single-element sequence).

process(rand(3))      # Implemented path    — zero-overhead dispatch
process(Point(1, 2))  # NotImplemented path — zero-overhead dispatch
```

#### Rust

```rust
// Static dispatch via trait bounds (positive case only).
fn process<T: IntoIterator>(x: T) -> Vec<T::Item> {
    x.into_iter().collect()   // monomorphized per T at compile time
}

// Two-branch design (any T, fallback for non-iterables) is not
// expressible in stable Rust:
// — specialization is nightly-only
// — negative trait bounds are unstable
// The canonical stable approach: two separate functions
// with different bounds, or a runtime enum/Any approach.
```

#### Go

```go
// Go: type switches are runtime checks, not static dispatch.
func process(x any) []any {
    if iter, ok := x.(interface{ Items() []any }); ok {
        return iter.Items()   // runtime branch
    }
    return []any{x}
}

// With generics a single-branch constraint is possible:
type Iterable[T any] interface { Items() []T }
func collect[T any](x Iterable[T]) []T { return x.Items() }

// But there is no static "NotIterable[T]" path —
// the two-branch pattern always requires a runtime type assertion.
```

!!! tip "Verdict — TC advantage for two-branch dispatch"
    TC's `interface_trait` + `Implemented`/`NotImplemented` gives genuinely *static* two-branch
    dispatch and is `juliac --trim` verified. Rust covers the positive case with zero overhead
    but has no stable mechanism for "T does NOT implement Trait, do X." Go's type switches cover
    both branches but are purely runtime.

---

## 5 · Delegation via Composition

Wrap a type, forward its interface, verify the delegation is complete.

#### Julia + TypeContracts

```julia
@contract Store begin
    store!(::Self, ::Int) :: Nothing
    fetch(::Self)         :: Int
end

mutable struct MapStore; value::Int; end
store!(s::MapStore, v::Int) = (s.value = v; nothing)
fetch(s::MapStore) = s.value

mutable struct Logged <: Store
    inner::MapStore; n_ops::Int
end
Logged() = Logged(MapStore(0), 0)

# Reads the contract, generates all forwarders, verifies:
@delegate Logged :inner Store
# Emits:
#   store!(_x1::Logged, _x2::Int) = store!(getfield(_x1, :inner), _x2)
#   fetch(_x1::Logged) = fetch(getfield(_x1, :inner))
# + satisfies() check (InterfaceError on failure)
```

#### Rust

```rust
trait Store {
    fn store(&mut self, value: i32);
    fn fetch(&self) -> i32;
}

struct MapStore { value: i32 }
impl Store for MapStore {
    fn store(&mut self, v: i32) { self.value = v; }
    fn fetch(&self) -> i32 { self.value }
}

struct Logged { inner: MapStore, n_ops: u32 }

// Deref forwards inherent method-call syntax but does NOT make
// Logged implement Store. Every trait method must be forwarded
// by hand — there is no stable delegation shortcut:
impl Store for Logged {
    fn store(&mut self, v: i32) {
        self.n_ops += 1;
        self.inner.store(v)   // manual forward
    }
    fn fetch(&self) -> i32 { self.inner.fetch() }
}
```

#### Go

```go
type Store interface {
    Store(key string, value int)
    Fetch(key string) int
}

type MapStore struct{ data map[string]int }
func (m *MapStore) Store(k string, v int) { m.data[k] = v }
func (m *MapStore) Fetch(k string) int    { return m.data[k] }

// Struct embedding promotes ALL MapStore methods to Logged.
// Logged implicitly satisfies Store — zero boilerplate:
type Logged struct {
    *MapStore        // all methods promoted automatically
    NOps int
}

// Override only what you want to customize:
func (l *Logged) Store(k string, v int) {
    l.NOps++
    l.MapStore.Store(k, v)
}
// Fetch is auto-promoted — no code needed at all.
```

!!! tip "Verdict — Go best; TC close"
    Go struct embedding is the strongest delegation story: it auto-promotes *all* methods of the
    embedded type with no interface contract required. TC's `@delegate` generates forwarders for
    the registered contract methods in one line and immediately verifies conformance. Rust has no
    stable delegation shortcut: `Deref` does not make a wrapper implement a trait, so every method
    must be forwarded by hand.

---

## 6 · Behavioral Invariants

Attach semantic laws to an interface and verify them against real objects.

#### Julia + TypeContracts

```julia
using TypeContracts

# Behavioral invariants — semantic laws on real instances, checked
# independently of any structural @contract on the same type:
struct Fraction
    num::Int
    den::Int
end

@invariants Fraction begin
    "denominator is never zero" =>
        f -> f.den != 0
    :optional
    "already in lowest terms" =>
        f -> gcd(f.num, f.den) == 1
end

# Run behavioral checks against real objects (test_behavior does not
# re-run structural checks — pair it with satisfies()/@verify for that):
test_behavior(Fraction, [Fraction(1, 2), Fraction(3, 4)])
# (passed=true, results=[...], mandatory_failures=[])
```

#### Rust

```rust
// Rust traits are purely structural — method signatures only.
// Semantic laws cannot be expressed in the trait.
// They live in documentation:

/// # Laws
/// Implementations must satisfy:
/// - `is_empty()` iff `len() == 0`
trait Collection {
    fn len(&self) -> usize;
    fn is_empty(&self) -> bool { self.len() == 0 }
}

// Property-based testing (proptest / quickcheck) can verify
// invariants but is external to the trait definition.
// There is no machine-readable link between a trait and
// its semantic laws.
```

#### Go

```go
// Go interfaces are purely structural.
// Invariants are expressed in comments only.

// Collection is a finite sequence of elements.
//
// Implementations must satisfy:
//   - IsEmpty() == (Len() == 0)
//   - Get(i) does not panic for 0 <= i < Len()
type Collection interface {
    Len() int
    IsEmpty() bool
    Get(i int) any
}

// Property-based testing via rapid or gopter can check
// these laws, but they are entirely separate from the
// interface definition and not verified automatically.
```

!!! tip "Verdict — TC unique"
    `@invariants` + `test_behavior` are TC-exclusive. Behavioral predicates are registered as part
    of the interface, attached to `?`-docs, and exercised against real instances in a single call.
    Both Rust and Go interfaces are purely structural: invariants live in documentation and require
    external property-based testing tools with no connection to the type system.

---

## 7 · Compile-Time Code Generation

Generate method bodies from type information for zero-overhead static dispatch.

#### Julia + TypeContracts

```julia
# @contract emits a per-interface @generated method for
# interface_trait. The generator runs at specialization time
# and emits a static chain of hasmethod() calls. juliac --trim safe.
@generated function interface_trait(::Type{AbstractShape}, ::Type{T}) where {T}
    # contract methods baked in at macro-expansion; no registry lookup
    return _build_trait_expr(AbstractShape, T, arg_lists, fns)
end

# _build_trait_expr (runs at specialization time, T concrete):
function _build_trait_expr(I, T, arg_lists, fns)
    checks = Expr[]
    for i in eachindex(fns)
        sig = _build_sig(arg_lists[i], T)
        push!(checks, :(hasmethod($(fns[i]), $sig)))
    end
    isempty(checks) && return :($(Implemented{I}()))
    cond = foldl((a,b) -> :($a && $b), checks)
    :($cond ? $(Implemented{I}()) : $(NotImplemented{I}()))
end
# @generated bodies have full access to the Julia type system:
# inspect types, emit arbitrary IR.
```

#### Rust

```rust
// All generics are monomorphized at compile time — one machine-code
// copy per concrete (fn, T) pair, automatic.
fn process<T: Iterator>(iter: T) -> Vec<T::Item> {
    iter.collect()
}

// Declarative macros for explicit codegen over type lists:
macro_rules! impl_display {
    ($($t:ty),*) => {$(
        impl std::fmt::Display for $t {
            fn fmt(&self, f: &mut std::fmt::Formatter)
                -> std::fmt::Result { write!(f, "{:?}", self) }
        }
    )*};
}
impl_display!(u8, u16, u32, u64);

// Procedural macros (derive) add reflection-like power
// but operate on token streams, not on types at runtime.
```

#### Go

```go
// Go 1.18+ generics monomorphize at compile time.
func Map[T, U any](s []T, f func(T) U) []U {
    out := make([]U, len(s))
    for i, v := range s { out[i] = f(v) }
    return out
}

// go generate: a shell directive that invokes external
// codegen tools (stringer, mockgen…) — a separate build
// step, not part of the type system.
//go:generate stringer -type=Direction
type Direction int
const (North Direction = iota; South; East; West)

// Go generics are intentionally limited: the generic body is
// constrained to what the type constraint permits; no registry
// lookup or arbitrary IR generation at specialization time.
```

!!! tip "Verdict — TC most powerful; Rust automatic"
    Julia's `@generated` can run essentially arbitrary Julia at specialization time — inspect the
    type system, emit arbitrary IR — the most powerful of the three in principle. `interface_trait`
    itself deliberately uses only a sliver of that power (concrete data baked in at macro-expansion
    time, a static `hasmethod` chain emitted at specialization time — no registry lookup, no
    closures, nothing that would violate the trimmer's world-age/purity assumptions) precisely
    *because* the full power of `@generated` is unsound to use carelessly at runtime. Rust's
    monomorphization is automatic for all generics and its procedural macros are powerful but
    operate on token streams, not types. Go generics are intentionally limited: the body must be
    valid for all types satisfying the constraint, and `go generate` is a separate build step
    entirely outside the type system.

---

## 8 · Parametric Interface Constraints

Contracts that involve the implementing type's own type parameters.

#### Julia + TypeContracts

```julia
@contract AbstractContainer{T} begin
    cget(::Self, ::Int)       :: T => "element at index"
    cset!(::Self, ::T, ::Int)    => "set element at index"
    clength(::Self)           :: Int
end

struct VecBox{T} <: AbstractContainer{T}
    data::Vector{T}
end
cget(b::VecBox{T}, i::Int) where T       = b.data[i]
cset!(b::VecBox{T}, v::T, i::Int) where T = (b.data[i] = v)
clength(b::VecBox)                        = length(b.data)

# T resolves to Int for VecBox{Int}; return types verified:
@verify VecBox{Int}
```

#### Rust

```rust
// Generic trait with an associated type
trait Container {
    type Item;
    fn get(&self, i: usize) -> Option<&Self::Item>;
    fn set(&mut self, i: usize, v: Self::Item);
    fn len(&self) -> usize;
}

struct VecBox<T> { data: Vec<T> }

impl<T> Container for VecBox<T> {
    type Item = T;
    fn get(&self, i: usize) -> Option<&T> { self.data.get(i) }
    fn set(&mut self, i: usize, v: T) { self.data[i] = v; }
    fn len(&self) -> usize { self.data.len() }
}
// Wrong associated type or missing method → compile error.
```

#### Go

```go
// Go 1.18+ generic interface
type Container[T any] interface {
    Get(i int) T
    Set(i int, v T)
    Len() int
}

type VecBox[T any] struct{ data []T }
func (v *VecBox[T]) Get(i int) T    { return v.data[i] }
func (v *VecBox[T]) Set(i int, x T) { v.data[i] = x }
func (v *VecBox[T]) Len() int        { return len(v.data) }

// VecBox[T] satisfies Container[T] implicitly.
var _ Container[int] = &VecBox[int]{}
```

!!! tip "Verdict — three-way tie"
    All three handle parametric interfaces well for the common case. Rust's associated types give
    the most precise per-impl type resolution. TC resolves type parameters from the concrete
    subtype's supertype chain at check time and additionally verifies inferred return types via
    Julia's type inferencer. Go's generic interfaces are the most recent addition and lack const
    generics, but cover the common case cleanly with the least boilerplate.

---

## 9 · Interface-Gated Methods

Accept only values that satisfy a named interface, with an informative error.

#### Julia + TypeContracts

```julia
struct DataStore
    backing::Dict{String, Vector{UInt8}}
end

# interface_trait dispatch — named contract, @generated,
# trim-safe, informative error on failure.
function store!(ds::DataStore, key::String, value::T) where T
    _store!(ds, key, value, interface_trait(Number, T))
end
_store!(ds, k, v, ::Implemented{Number}) =
    (ds.backing[k] = reinterpret(UInt8, [v]); nothing)
_store!(ds, k, v, ::NotImplemented{Number}) =
    throw(InterfaceError("$(typeof(v)) is not a Number"))

store!(DataStore(Dict()), "x", 3.14f0)   # ok
store!(DataStore(Dict()), "x", "hello")  # InterfaceError
```

#### Rust

```rust
use std::collections::HashMap;

struct DataStore { backing: HashMap<String, Vec<u8>> }

impl DataStore {
    // T must satisfy the bounds at compile time.
    // Wrong T → compile error naming the unsatisfied trait.
    fn store<T: num_traits::Num + bytemuck::Pod>(
        &mut self, key: &str, value: T,
    ) {
        self.backing.insert(
            key.to_string(),
            bytemuck::bytes_of(&value).to_vec(),
        );
    }
}
// ds.store("x", "hello")
// error[E0277]: `&str` does not implement `Num`
```

#### Go

```go
type DataStore struct{ backing map[string][]byte }

// Go 1.18+ generic constraints CAN gate on a method set at compile time —
// this is not limited to type unions:
type Bytesable interface{ Bytes() []byte }

func StoreBytes[T Bytesable](ds *DataStore, key string, val T) {
    ds.backing[key] = val.Bytes()
}
// StoreBytes(ds, "x", "hello") — compile error if string has no Bytes() method.

// For *numeric* types specifically, Go has no operator-overloading trait,
// so gating on "is a number" needs a union of concrete underlying types
// instead of a method set:
type Numeric interface {
    ~int | ~int32 | ~int64 | ~float32 | ~float64
}

func Store[T Numeric](ds *DataStore, key string, val T) {
    // encode val...
}

// Store(ds, "x", "hello") — compile error:
//   string does not satisfy Numeric
```

!!! tip "Verdict — Rust wins; TC and Go both close, differently"
    Rust's trait bounds enforce the full method signature at compile time — the strongest
    guarantee of the three. TC's `interface_trait` fires at load time (via `@verify`) or at
    runtime (the `NotImplemented` branch) and checks method *existence* only, not return
    types — weaker than Rust's compile-time signature check. Go's generic constraints can gate
    on a method set at compile time just as well as Rust for the general case; *numeric* gating
    specifically needs a union of concrete underlying types, since Go has no operator-overloading
    trait to express "supports +, -, *, /" as a method set — a domain-specific limitation, not a
    general one.

---

## Summary

| # | Pattern | Julia + TC | Rust | Go | Verdict |
|---|---------|-----------|------|----|---------|
| 1 | Default/optional methods | `:optional` + separate fallback method; optional/required distinction machine-readable | default body co-located in `trait`; type-checked by compiler | no defaults; base-struct embedding; invisible to interface tooling | Rust co-location; TC queryability |
| 2 | Interface hierarchies | abstract type chain; `@verify` checks all levels | `trait B: A` supertraits; separate `impl` per level | interface embedding | three-way tie |
| 3 | Extending foreign types | retroactive `@contract` on any abstract type, no wrapper | wrapper only (orphan rule) | implicit if methods exist; wrapper if methods missing | TC advantage |
| 4 | Type-level dispatch | `interface_trait` → static two-branch, trim-safe, existence-only (no return-type check) | trait bound (positive only; negative unstable) | runtime type switch only | TC advantage |
| 5 | Delegation | `@delegate Wrapper :field Interface` — generates + verifies mandatory methods only | manual `impl Trait`, every method by hand | struct embedding — all methods promoted automatically | Go best; TC close |
| 6 | Behavioral invariants | `@invariants` + `test_behavior` — part of interface | structural only; laws in docs/external tests | structural only; laws in docs/external tests | TC unique |
| 7 | Compile-time codegen | `@generated` — full Julia at specialization time | automatic monomorphization; procedural macros on tokens | generic monomorphization; `go generate` is external | TC most powerful; Rust automatic |
| 8 | Parametric constraints | `@contract AbstractType{T}`; T resolved + return types verified | generic traits + associated types + const generics | generic interfaces; no const generics | three-way tie |
| 9 | Interface-gated methods | `interface_trait` + `InterfaceError` (existence-only; load/runtime) | `where T: Trait` (compile-time, full signature) | method-set or union constraint (compile-time) | Rust wins; TC and Go close |
| — | Live re-checking | Revise.jl — re-checks all registered types after each edit, warns without throwing | enforced on every build | enforced on every build; `var _ I = T{}` | TC differentiator |
| — | Static-binary compat | `interface_trait` trim-safe by design; `@verify T trim_compat=true` runs a shallow heuristic IR scan (not an exhaustive proof) | always compiled to native | always compiled to native | TC bridges Julia's dynamic gap |

---

## Key Differences

**Implicit vs explicit satisfaction.** Go's structural typing is the most permissive — a type
satisfies an interface by having the right methods with no declaration. Rust requires an explicit
`impl Trait for Type` per type per trait. TC is structural in substance but requires an explicit
`@verify T` or `@verify_all` call to trigger the check.

**When violations are caught.** Rust catches trait violations at compile time. Go catches them
at compile time when a type is used as an interface, or immediately via `var _ I = T{}`
assertions. TC catches them at module *load* time — later than Rust and Go, but far earlier than
a production runtime error, and without a recompile step.

**Default method bodies.** Rust's default bodies are part of the trait definition — discoverable,
inherited, overridable, and verified by the compiler. TC's `:optional` + abstract-type fallback
achieves the same result and is machine-readable, but the fallback is structurally decoupled
from the contract declaration. Go interfaces have no default bodies.

**Retroactive contracts.** TC attaches a formal, verifiable, documented contract to *any* abstract
type — no wrapper needed. Go's implicit structural typing means a type that already has matching
methods satisfies a new interface automatically, but adding new methods to foreign types requires
a wrapper. Rust's orphan rule prevents implementing a foreign trait for a foreign type entirely.

**Contract coherence.** TC stores each `@contract`/`@invariants` registration as a single method
on `_contract_specs`/`_behavior_specs` keyed by the abstract type — there is only one such
registration per type. A second package registering `@contract` for a type another package
already contracts does not merge with it; it overwrites it (`@contract` now emits a `@warn` when
this happens, but two packages precompiling the same overwrite independently can still hard-error
at precompile time). This is exactly the coherence problem Rust's orphan rule and Go's
per-consumer interface declarations are designed to prevent: TC trades that safety for the
ability to attach contracts to foreign types, and the tradeoff needs care in any ecosystem where
more than one package might contract the same type.

**Delegation.** Go struct embedding auto-promotes *all* methods of the embedded type with zero
boilerplate. TC's `@delegate` generates forwarders for the registered contract methods in one
line and immediately verifies conformance. Rust has no stable delegation shortcut: every trait
method must be forwarded by hand.

**Behavioral invariants.** TC's `@invariants`/`test_behavior` encode semantic laws as part of
the interface and test them against real instances. Both Rust and Go interfaces are purely
structural; invariants must live in documentation and be verified by external property-based
testing tools.

**Two-branch dispatch.** TC's `interface_trait` + `Implemented`/`NotImplemented` gives static,
trim-safe dispatch for both "satisfies" and "does not satisfy" at the same call site — but it
checks method *existence* only, not return types, weaker than Rust's compile-time signature
check for the positive case. Rust's generics handle the positive case statically but negative
trait bounds are not stable. Go requires a runtime type switch for the two-branch pattern.

**Live re-checking during development.** Loading [Revise.jl](https://github.com/timholy/Revise.jl)
alongside TypeContracts re-checks all `@verify`-registered types after each edit, emitting
`@warn` so the REPL stays alive. Rust and Go catch violations on the next build — a different
latency model, but TC's approach uniquely fits Julia's interactive development workflow.

**Static-binary compatibility.** Julia is JIT-compiled; producing a static binary via
`juliac --trim` requires care. TC's `interface_trait` is `@generated` and trim-safe *by design*
(no CI job in this repo currently builds and runs an actual `juliac --trim` binary, so treat this
as a strong design argument, not an empirical guarantee). `@verify T trim_compat=true`
additionally runs a shallow, heuristic scan of typed IR for known trim-unsafe calls in the
implementation methods — it can miss patterns it doesn't recognize. Both Rust and Go compile
directly to native code — static binary compatibility is the baseline, not a concern.

**Return-type checking is inference-dependent.** `check_contract`/`satisfies` resolve declared
return types via `Base.return_types`, which can widen to a `Union` (or `Any`) for type-unstable
methods — a correct implementation that happens to be type-unstable can fail a return-type check
that neither Rust nor Go would ever attempt, since both check *declared*, not *inferred*, return
types. `@verify_all` pays this inference cost for every concrete subtype in a module at load
time, which can add up in modules with many implementers.
