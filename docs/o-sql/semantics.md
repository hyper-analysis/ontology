# O-SQL evaluation contract

[Specification](README.md) · [BNF](grammar.bnf) · [Typing](typing.md)

## 1. Worlds, bindings and results

Fix a checked ontology Σ and a finite reference snapshot W conforming to it.
W contains root populations and data, explicit optional presence, collection
memberships, finite map entries and alternative tags. Reference cycles use
entity designators rather than recursively copied records. By-value shape is
finite as checked by the ontology.

Let ρ supply actual values for the names in Γ. A type declaration alone never
identifies which object a name denotes. Evaluation is written:

$$
\langle e,W,\rho\rangle\Downarrow v
\qquad\text{or}\qquad
\langle e,W,\rho\rangle\Uparrow F
$$

W remains fixed during one program evaluation. These are reference-data
operations, not temporal mental changes. Diagnostics do not become memory.

Runtime values have these semantic shapes. This display notation is not an
additional source grammar:

```text
Scalar(value)
Entity(population, semanticKey)
Record{ field ↦ value, ... }
Set{ value, ... }
Sequence[ value, ... ]
null
Map{ namedArgumentTuple ↦ value, ... }
Variant(tagName, activeBranch, payload)
```

An entity supports record access through W. An owned record is a value at its
owner's location, without independent population identity. A map's named
argument tuple is independent of the order written at a call site. `null`,
`Record{}`, `Set{}` and `Sequence[]` are distinct. A present record whose
optional fields are all absent is also distinct from an absent record.

## 2. Basic evaluation

`root` returns W's root value; names return their values from ρ. Literals return
scalar values. Parentheses group subexpressions and delimit optional-chain
propagation. Record expressions evaluate
their fields and construct values without inserting entities into W.

The literal null and actual optional absence produce the query value null.
Ordinary `e.f` evaluates e, raises MissingValue for a null receiver and otherwise
returns the declared field value. That field may itself be null successfully.
A reference field returns a target entity designator; subsequent selections
preserve the semantic traversal. Null is not an entity with absent fields.

Optional access `e?.f` returns the field for a present receiver; a null receiver
short-circuits the remaining continuous postfix chain. The skipped suffix yields
null at the chain boundary. During evaluation distinguish Active(v) from an
internal Skip state:

```text
Active(null).f      raises MissingValue
Active(v).f         = Active(field(v,f))              when v is non-null
Active(null)?.f     = Skip
Active(v)?.f        = Active(field(v,f))              when v is non-null
Skip.f             = Skip
Skip?.f            = Skip
Skip(arguments)    = Skip                            arguments not evaluated
end-chain(Skip)    = null
end-chain(Active(v)) = v
```

Operators, record fields, match arms and argument boundaries consume a completed
expression; they do not pass Skip outside that postfix chain. Parentheses may
group conditions or nested queries, but cannot acquire field/call suffixes.
`(person.teacher?.school).name` and computed fields such as `a.(field)` are syntax
errors. `person.teacher?.school.name` skips its suffix if teacher is null, but
throws if teacher is present and school is null. Errors computing the receiver
are never suppressed by `?.`.

A projection cutoff, an unrequested field in partial JSON, unavailable backend
data or lack of an observation capability does not establish absence. Fetch
permitted required data or report UnavailableData. A dangling required reference
is invalid-instance data, not an optional missing target.

## 3. Keyed lookup and map application

For S a set of Entity(E) values, normalize arguments to E's declared named key:

```text
matches = { x ∈ S | semanticKey(x) = suppliedKey }

S(arguments) = null             when |matches| = 0
S(arguments) = x                when matches = {x}
S(arguments) = IntegrityFailure when |matches| > 1
```

The last case detects invalid data. Repeated occurrences of the same entity
are one set member; inconsistent records claiming the same identity are an
integrity error, not two independent identities.

Lookup is relative to S. If a query filtered Alice out, looking her up in that
result returns null even if she exists in the full population. A constructed
record containing a key-looking field does not become an entity.

A finite partial map normalizes its declared named argument tuple similarly:

```text
M(arguments) = null       when the tuple is outside its stored domain
M(arguments) = v          when that tuple maps to v
```

An active call requires a non-null callee; a null map or nullable-set callee
raises MissingValue before lookup. A skipped optional chain does not call it or
evaluate arguments. A successful lookup returning null is not an error.
Executed arguments must be non-null Keyable values of the declared types;
a nullable argument that evaluates to null raises MissingValue, rather than
searching for a null key or treating the argument as omitted.

Declaring a key or map does not enumerate arguments or create entries. Composite
Keyable record/reference arguments retain their values; SQL adapters may flatten
them using the existing semantic key routes.

`entries(M)` returns the set of `Record{key: argumentRecord, value: v}` values
for the finite stored domain of M. Empty maps give an empty set. Different named
argument tuples remain different entry records even when their values designate
the same entity. A later projection can intentionally forget those keys.

## 4. Match and null-demanding operations

Evaluate a match scrutinee exactly once. It must produce a value of the checked
named alternative. Select the arm matching its active branch, bind the payload
in that arm's lexical scope, and evaluate its expression. If no named arm covers
that branch, evaluate the checked final fallback in the enclosing scope.
All inactive arms are unevaluated, including their sources, fields and calls.

```text
match Variant(tag, b, payload) {
    b x => result;
    ...
}
    = evaluate result with x bound to payload
```

The payload binding is definite; it may contain optional fields. It is local to
its arm and does not modify the source alternative. Different arms may produce
different value shapes. Return the selected value directly without adding an
output tag or padding other arms' fields with null. A union is a static set of
possible value types, not a new runtime wrapper. Include an explicit result
field if a consumer needs a discriminator.

A null scrutinee raises MissingValue. `_` covers unlisted branches of the known
alternative; it does not catch null or exceptions. An undeclared active tag or
missing required active payload is invalid/unavailable data, not a fallback.
Static checking validates every arm, exhaustiveness and branch labels before
execution. Null-returning arms succeed normally.

Operations that require a non-null map, set/sequence, Boolean or ordered scalar
raise MissingValue on an executed null input. This includes `entries`, `count`,
`only`, `first`, `at`, source iteration, bounded quantification, Boolean operands
and ordered comparisons. Null is never implicitly an empty map/set or false.
Known unrelated non-null types remain static errors. Short-circuited Boolean
operands and inactive match arms remain unevaluated.

There are no separate present/require/branch builtins in this source core.
The canonical presence check is `not (e = null)`.

## 5. Equality and scalar comparison

- Entities compare resolved population identity and complete semantic keys.
  Display labels and SQL surrogate IDs do not determine equality. Two traversal
  paths may designate one entity without losing their distinct path provenance.
- Records compare corresponding fields independently of field order.
- Sets compare membership; sequences compare ordered positions and repetitions.
- Finite maps compare named argument tuples and associated values independently
  of enumeration order. Examining a finite map is not deciding arbitrary host
  function equality.
- Variants compare tag, active branch and corresponding payload.
- Scalars compare within their primitive family. Numbers are exact finite
  decimals, so 1 = 1.0. Timestamps compare instants. Text compares Unicode scalar
  sequences exactly. Different scalar families are unequal where a compatible
  refined type permits the comparison.

Null-aware equality is Boolean:

```text
null = null          -> true
null = nonNullValue  -> false
nonNullValue = null  -> false
```

Non-null values use the structural/identity cases above. Different runtime value
constructors, scalar families, record label sets or entity populations compare
unequal when their static union types permit the comparison. Union membership
adds no hidden tag. Equality changes neither operand's type nor presence.
Ordinary field access inside an operand can still fail before comparison:
`missing.city = null` throws, while `missing?.city = null` is true for a null
missing value. Equality does not implement SQL's three-valued NULL comparison.
Ordered comparisons demand non-null numbers or timestamps. Membership demands
a non-null range, compares its elements by equality and introduces no binding
or index; a null candidate can match a null member.

## 6. Logic and quantification

Booleans are two-valued. `and` evaluates its right operand only when the left is
true; `or` only when the left is false. `not` negates its operand. `P implies Q`
evaluates Q only if P is true, otherwise returning true. Evaluated operand errors
propagate; unevaluated operands contribute no error. Null or unavailable data
does not become cognitive Unspecified or an invented false condition.

`exists(Q)` evaluates Q and tests whether its result set is nonempty.
`exist!(Q)` (also spelled `exists!(Q)`) evaluates a set-valued expression and
tests whether its distinct result set has exactly one member. Q can be a query
or a variable already holding a set; no reevaluation of its original source is
implied by using that variable. It returns false for zero or multiple members.
The unique predicate does not itself perform a cardinality assertion; assertions
inside its argument still execute normally. Executed query failures propagate;
false does not swallow MissingValue or unavailable data. Bounded
`exists x in S { P }` and `every x in S { P }` evaluate S outside the new binder,
then test P under each member binding. Empty ranges give false and true
respectively. No witness is installed in cognitive state.

Bounded quantification is strict over its range: an error in any member body
fails it, even if another member supplies a true existential or false universal
case. Thus unordered enumeration cannot decide whether an error is hidden.
Within each member body Boolean short-circuiting still applies. Query-existence
and the equivalent bounded existence agree when filter/projection introduce
the same evaluated work and no additional failure.

## 7. Ordered query steps

A query starts with one outer binding environment. Sources/steps transform a
finite collection B of environments. Bindings retain provenance and are not
merged merely because some bound values coincide. Deduplication happens at yield
of the final selected values, without a separate source `yield` keyword.

```text
from S as x:
    for every ρ in B, evaluate S under ρ
    replace ρ by all extensions ρ[x ↦ v] with v in that set

let x = e:
    for every ρ in B, evaluate e under ρ
    replace ρ by ρ[x ↦ value(e,ρ)]

where P:
    for every ρ in B, evaluate P under ρ
    retain exactly those ρ for which P is true
```

Sources run left-to-right, then `let`/`where` steps in written order. Finally
evaluate the projection for each surviving environment. Named projections form
records; a bare projection returns its value. Collect outputs into a set S.

```text
select  ...   returns S
select! ...   returns the member when |S| = 1
select! ...   raises CardinalityFailure when |S| ≠ 1
exist!(select ...) returns (|S| = 1)
```

Count distinct projected values, not source witnesses. Two people whose city is
Paris yield one city; a person projection retains both identities. A projected
null is a value: the singleton set {null} has cardinality one and `select!`
returns null successfully. Errors during required query work propagate before
cardinality is decided. A backend cannot hide a later evaluated error by stopping
a unique query after its first witness. No first-result or limit syntax is added.

An error in a required source, step or surviving projection fails the query.
`let` is strict even when its name is unused. A false `where` removes its binding
before later steps. When B is empty, no later per-binding evaluations occur;
static checking still checks all source, step and projection syntax.

```text
select teacherCity
from root.people as person
let teacher = person.teacher
where not (teacher = null)
let teacherCity = teacher.city
```

Absent teachers remove their binding before field access. Moving the last `let`
before the filter may fail the entire query. Filters cannot move across partial
computations without a semantics-preserving argument.

## 8. Cardinality, sequence operations and programs

```text
count(Set S)       = number of distinct members
count(Sequence S)  = number of positions
only(C)           = the sole member, when cardinality(C) = 1
only(C)           raises CardinalityFailure otherwise
first([])         = null
first([v,...])    = v
at(S,i)           = S[i] when i is integral and 0 ≤ i < length(S)
at(S,i)           = null when i is integral and out of range
at(S,i)           raises InvalidIndex when i is not integral
```

`first`/`at` reject Sets statically. A database serialization order does not make
a set a sequence. A negative integral index is out of range and returns null.

Top-level definitions evaluate strictly in order before the final expression.
Their binding is nonrecursive. An ordinary query binding stores its Set result;
a `select!` binding stores the single projected value, or stops evaluation with
CardinalityFailure. A binding does not persist a view or defer the query as syntax. A standalone selected field can return Text or
a standalone keyed lookup Optional(Person), without a singleton-row select.

## 9. Failures and backend conformance

| Outcome | Meaning |
| --- | --- |
| null | Successful evaluation of the absence literal or actual optional absence |
| Empty set/sequence | Successful evaluation with no members/positions |
| Static diagnostic | Source fails checking before evaluation |
| MissingValue | An executed ordinary field access or other demanding operation received null |
| CardinalityFailure | Executed only or select! encountered zero or multiple distinct results |
| InvalidIndex | Executed at received a nonintegral numeric index |
| IntegrityFailure | Input violates ontology identity/shape obligations |
| UnavailableData | Evaluation environment cannot supply required data |
| UnsupportedLowering | Checked form has no supported backend interpretation |
| Technical interruption | Resource/cancellation safeguard, not a query result |

When several unordered bindings fail, diagnostic ordering/which failure is
reported first is unspecified. Success cannot depend on hiding an evaluated
failure. Budget exhaustion is not absence, falsehood or an empty/exhaustive set.

SQL interpretation must preserve semantic identities, key/argument binding,
presence markers, branch activity, lazy match/optional-chain evaluation,
heterogeneous result shapes, finite set/map equality, correlation and ordered
partial-computation behavior. A present empty record
cannot collapse into NULL. Projecting city values must implement set results.

SQL optimizer freedom is not conformance. Lowering may require explicit presence
or result encodings, guarded expressions, checked stages or barriers. If the
backend cannot preserve this contract, report UnsupportedLowering. The future
in-memory interpreter should independently check the same results/failures; this
document does not claim that it exists yet.

A backend may construct named PostgreSQL composites and arrays for stable shapes
and use `to_jsonb` for serialization; heterogeneous arms may instead construct
JSONB objects directly. These are lowering options, not additional source types.
The compiler still assembles relationships/collections and distinguishes an
absent object from a present empty/all-null object. Serialization cannot enforce
ordinary-dot failures or lazy arm behavior by itself. See PostgreSQL's
[JSON creation functions](https://www.postgresql.org/docs/current/functions-json.html#FUNCTIONS-JSON-CREATION-TABLE).

