# O-SQL typing sequents

[Specification](README.md) · [BNF](grammar.bnf) · [Evaluation](semantics.md)

## 1. Judgments and assumptions

Let Σ be the checked ontology and its read-only semantic signatures. It supplies
the root, entity populations, declared keys, fields, maps and named alternatives.
It is not a database instance. Let Γ map lexical names to query types. Evaluation
separately supplies actual values ρ satisfying those types; Γ alone never
identifies which person an `alice` name denotes.

The main judgment is:

$$
\Sigma;\Gamma\vdash e:\tau
$$

It says that expression e has type τ. It asserts neither that e evaluates
successfully nor that any object satisfying a lookup exists.

Types are:

```text
τ ::= Text | Number | Boolean | Timestamp
    | Literal(v) | Enum(L)
    | Entity(E)
    | Record{ f₁:τ₁; ...; fₙ:τₙ }
    | Variant(tag; b₁:τ₁; ...; bₙ:τₙ)
    | Null | Union(τ₁, ..., τₙ)
    | Set(τ) | Sequence(τ)
    | Map((a₁:σ₁, ..., aₙ:σₙ), τ)
```

`Person` in source explanations abbreviates `Entity(Person)` when it designates
a population member or reference target. An ordinary by-value Person-shaped
record is a Record value, preserving its field/ownership interpretation. It
does not acquire independent population identity.

`Optional(τ)` is an abbreviation for `τ ∨ Null`, not a wrapper constructor.
Write τ ∨ σ for the normalized finite union of the two types. Flatten nested
unions, remove duplicate or subsumed alternatives, and collapse a one-member
union. Optional(Optional(τ)) = Optional(τ). This extends query result types;
it does not permit arbitrary unions in `.ontology` declarations. A union adds
no runtime tag or conversion. In particular, different record shapes remain
different possible shapes, not one record with newly optional fields.

`Literal(v)` and `Enum(L)` retain ontology refinements. Output type displays may
widen literal refinements to the corresponding primitive when explaining a
result, but checkers must retain refinements needed by argument checking.

## 2. Ontology-derived signatures

The semantic interpretation of the existing ontology supplies:

```text
rootΣ                    : Record{ root fields }
fieldΣ(τ, f)             : result type, if declared
keyΣ(E)                  : (k₁:κ₁, ..., kₙ:κₙ), n ≥ 1
branchΣ(V, b)            : payload type, if b is a declared branch
```

Root population fields have types `Set(Entity(E))`. Ordinary record fields use
their by-value meanings; `Ref<E>` fields produce `Entity(E)` designators.
Optional fields add `Optional`, collections add `Set`, and ontology functions
produce Map signatures. Alternative tag/branch structure is retained as a
Variant. These signatures reuse the checked ontology, rather than trusting a
signature attached by an O-SQL caller.

The complete values of immediate key-marked fields contribute to `keyΣ(E)`.
Nested key annotations do not bubble upward or narrow a marked field's value.
Key/map argument types remain the existing finite Keyable types. References
inside keys identify their target entity by semantic key. SQL surrogate IDs and
integrity-only `unique` annotations do not contribute key arguments.

`fieldΣ` is defined for definite Entity and Record subjects. On a non-null
union it requires the field on every possible subject type and unions those
field result types. It never traverses a Set or Sequence implicitly. For an
Entity, field selection retains
the semantic reference traversal needed to access its record. No separate
user-visible dereference expression is required in the surface language.

## 3. Variables, root, literals and records

$$
\frac{\Gamma(x)=\tau}{\Sigma;\Gamma\vdash x:\tau}
\qquad
\frac{}{\Sigma;\Gamma\vdash\mathrm{root}:\mathrm{root}_{\Sigma}}
$$

Text, numeric and Boolean literals have singleton types Literal(v).
The absence literal has its own rule:

$$
\frac{}{\Sigma;\Gamma\vdash\mathrm{null}:\mathrm{Null}}
$$

`timestamp(STRING)` has type Timestamp after validating the literal. Text and
numeric lexical restrictions are part of the specification, not truth tests.

For record construction:

$$
\frac{
  \Sigma;\Gamma\vdash e_i:\tau_i\;(1\le i\le n)
  \qquad f_i\text{ pairwise distinct}
}{
  \Sigma;\Gamma\vdash\{f_1:e_1,\ldots,f_n:e_n\}:
  \operatorname{Record}\{f_1:\tau_1,\ldots,f_n:\tau_n\}
}
$$

This includes an empty Record. Record labels are not lexical bindings.

## 4. Assignability

Write σ ≼ τ when a σ value can be supplied where τ is required. It is the
smallest reflexive, transitive relation containing:

```text
τ ≼ τ
Literal(v) ≼ primitive(v)
Literal(v) ≼ Enum(L)                    if v ∈ L
Enum(L) ≼ primitive p                  if every v ∈ L has primitive p
Enum(L₁) ≼ Enum(L₂)                     if L₁ ⊆ L₂
```

Union assignability is defined by coverage: every alternative of the source
must be assignable to at least one alternative of the target. Thus τ ≼ τ ∨ σ
and Null ≼ Optional(τ). This inclusion does not wrap or convert a value.
Assignability is covariant for Set and Sequence. Records require the
same field-label set and assignable corresponding fields. There is no implicit
record-width projection, collection flattening, or entity-to-record conversion.
Entity identity types match the same
resolved population; spelling aliases must be resolved first.
Maps and Variants retain their declared signatures; this core adds no variance
rule for them beyond identical types and resolved aliases.

This relation permits a known `"active"` argument for an `"active" | "inactive"`
parameter. An arbitrary Text argument cannot promise that refinement. Narrowing
unknown runtime values requires an explicit future construct, not an unchecked
cast hidden in lookup.

## 5. Non-null demand and postfix chains

Let nn(τ) remove Null alternatives, retaining all other alternatives. If it is
empty, an operation cannot infer an owner, callee or collection shape from that
input alone. Nullable types with a suitable non-null part may be used by strict
operations, recording a possible runtime MissingValue failure:

$$
\frac{\Sigma;\Gamma\vdash e:\tau\qquad
      \operatorname{nn}(\tau)=\sigma\ne\varnothing}
     {\Sigma;\Gamma\vdash_d e:\sigma}
$$

This judgment demands an actual non-null value; it is not an assignability rule,
proof of presence or update to Γ. Boolean conditions, ordered comparisons,
collection consumers, map callees, key/map arguments and match scrutinees use
this demand judgment. For an operation over a heterogeneous non-null union,
check its required signature against every alternative and union the results;
reject any unsupported possibility. Collection iteration binds the union of
possible element types. A match scrutinee must resolve to one declared Variant
signature; structural matching of arbitrary result unions is outside this core.
Equality and optional chaining have their own null behavior.

A postfix chain needs to distinguish an actual null field from a skipped suffix.
Use an auxiliary judgment Σ;Γ ⊢post p : τ ▷ s. Here τ is the value type along
active paths and s is a Boolean flag indicating that an earlier `?.` may already
have skipped the chain. Skip is internal control state, not a source value/type.

For an unparenthesized primary a:

$$
\frac{\Sigma;\Gamma\vdash a:\tau}
     {\Sigma;\Gamma\vdash_{post}a:\tau\triangleright\mathrm{false}}
$$

For ordinary field access:

$$
\frac{\Sigma;\Gamma\vdash_{post}p:\tau\triangleright s\qquad
      \operatorname{field}_{\Sigma}(\operatorname{nn}(\tau),f)=\sigma}
     {\Sigma;\Gamma\vdash_{post}p.f:\sigma\triangleright s}
$$

On an active path, a null receiver throws. A previously skipped chain remains
skipped. For optional field access:

$$
\frac{\Sigma;\Gamma\vdash_{post}p:\tau\triangleright s\qquad
      \operatorname{field}_{\Sigma}(\operatorname{nn}(\tau),f)=\sigma}
     {\Sigma;\Gamma\vdash_{post}p?.f:\sigma\triangleright
       (s\lor\operatorname{nullable}(\tau))}
$$

On an active path, a null receiver now skips the suffix instead of throwing.
Unknown fields and non-record/non-entity possibilities remain static errors.
For postfix application, let CallΣ;Γ(nn(τ),A) = σ denote the result of applying
the argument/callee rules in section 6 to the non-null callee type:

$$
\frac{\Sigma;\Gamma\vdash_{post}p:\tau\triangleright s\qquad
      \operatorname{Call}_{\Sigma;\Gamma}(\operatorname{nn}(\tau),A)=\sigma}
     {\Sigma;\Gamma\vdash_{post}p(A):\sigma\triangleright s}
$$

Arguments are checked in the current scope even on a possibly skipped path.
An active null callee throws; skipped calls evaluate neither the callee
operation nor its arguments.

When a complete postfix expression is consumed, turn the skip possibility into
ordinary absence:

$$
\frac{\Sigma;\Gamma\vdash_{post}p:\tau\triangleright s}
     {\Sigma;\Gamma\vdash p:
       \begin{cases}\tau\lor\mathrm{Null}&s=\mathrm{true}\\
                      \tau&s=\mathrm{false}\end{cases}}
$$

Consequently `person.teacher.city : Text` may throw, while
`person.teacher?.city : Optional(Text)` does not throw merely because teacher is
absent. In `person.teacher?.school.name`, an absent teacher skips the suffix;
a present teacher whose school is null still throws at `.name`.
Parenthesized expressions may group conditions/queries, but cannot be the
receiver of any postfix field or call: `(person.teacher?.school).name` is a syntax
error, not another navigation form. Field labels are literal names; computed
attribute selection is not in the AST/grammar. No flow refinement is required.

## 6. Application arguments

Write:

$$
\Sigma;\Gamma\vdash A\Leftarrow(k_1:\kappa_1,\ldots,k_n:\kappa_n)
$$

when application arguments A satisfy a signature. Named arguments must contain
exactly those labels, once each. If argument k_i is e_i, require:

$$
\Sigma;\Gamma\vdash_d e_i:\sigma_i\qquad\sigma_i\preceq\kappa_i
$$

The single positional form `e(v)` is equivalent to the named form only when
there is exactly one declared argument. Composite signatures require names.
Named argument order is immaterial. No implicit defaults or omitted arguments
are supplied.

Nullable arguments with the appropriate non-null type are accepted with a
possible MissingValue failure; null is not a key value or an omitted argument.

Source argument labels are the ontology's declared key/parameter names. Generated
flattened wire names such as `root_1__name` from the existing prepared-read API
are not source names. A backend adapter must retain the semantic key routes and
flatten source values into that API's parameters when reusing it.

For entity-key lookup:

$$
\frac{
 \Sigma;\Gamma\vdash_d S:\operatorname{Set}(\operatorname{Entity}(E))
 \qquad\operatorname{key}_{\Sigma}(E)=K
 \qquad\Sigma;\Gamma\vdash A\Leftarrow K
}{
 \Sigma;\Gamma\vdash S(A):\operatorname{Optional}(\operatorname{Entity}(E))
}
$$

For partial-map application:

$$
\frac{
 \Sigma;\Gamma\vdash_d M:\operatorname{Map}(K,\tau)
 \qquad\Sigma;\Gamma\vdash A\Leftarrow K
}{
 \Sigma;\Gamma\vdash M(A):\operatorname{Optional}(\tau)
}
$$

Application is not a general host-function call. An expression with another
callee type is rejected. A projection record containing key-looking fields
does not thereby become Entity(E) or support entity-key lookup.

## 7. Map enumeration and heterogeneous match

Finite map enumeration has the rule:

$$
\frac{\Sigma;\Gamma\vdash_d M:\operatorname{Map}((a_i:\sigma_i)_{i=1}^{n},\tau)}
     {\Sigma;\Gamma\vdash\mathrm{entries}(M):
      \operatorname{Set}(\operatorname{Record}\{
        \mathrm{key}:\operatorname{Record}\{a_i:\sigma_i\}_{i=1}^{n};
        \mathrm{value}:\tau\})}
$$

This computed result shape does not relax ontology restrictions on stored
collections of maps or keyability. A null map raises MissingValue when consumed;
it is not an empty map.

Let V = Variant(tag; b₁:π₁, ..., bₙ:πₙ). For an exhaustive match:

$$
\frac{
 \Sigma;\Gamma\vdash_d e:V\qquad
 \Sigma;\Gamma[x_i:\pi_i]\vdash r_i:\tau_i\quad(1\le i\le n)
}{
 \Sigma;\Gamma\vdash
 \mathrm{match}\ e\ \{b_i\ x_i\Rightarrow r_i;\}_{i=1}^{n}:
 \bigvee_{i=1}^{n}\tau_i
}
$$

The written branch labels must equal V's declared labels, each once, in any
order. Each payload binder is local to that arm. All result types are allowed;
there is no requirement to find one shared record/collection/scalar shape.
The union retains every possible arm result and erases duplicate alternatives.

For named arms I and a final fallback `_ => r₀;`, require I to be a proper
subset of the declared branch set, with no duplicate labels. Check each named
arm as above and Σ;Γ ⊢ r₀:τ₀ in the enclosing scope, without a payload binder.
The result type is (⋁ᵢ∈I τᵢ) ∨ τ₀. A fallback after complete coverage is rejected
as unreachable. A match needs at least one arm.

Example:

```text
match person.role {
    Resident resident => resident.city;
    Visitor visitor => { destination: visitor.destination };
}
```

Its type is `Text ∨ Record{destination:Text}`. A match returning Text in one arm
and null in the other has type Optional(Text). The scrutinee's branch tag is not
automatically copied onto result values. Accessing a field on a union later
requires it on every non-null alternative; branch-specific fields are not
invented on other result shapes. Further source-variant access uses another
match on that variant, not structural pattern matching on arbitrary JSON.

## 8. Comparisons and logic

Define EqCompatible(τ,σ) structurally:

- Identical resolved Entity types are compatible.
- Atomic types are compatible when their possible primitive-family sets overlap.
  Runtime atomic values from different families are unequal.
- Records with the same label set, and two Sets or two Sequences, are compatible
  when their corresponding component types are compatible.
- Variants with the same declared tag/branch signature are compatible.
- Null can be compared with any query type. Null equals only null.
- A union comparison is allowed when at least one pair of alternatives is
  compatible by these rules. At runtime, different scalar families, entity
  populations, record label sets or value constructors are unequal. This also
  defines equality between heterogeneous members during set deduplication.
- Maps with the same named-argument signature are compatible when their
  corresponding argument and result types are compatible. Ontology maps are
  finite partial mappings, so equality is extensional over their stored entries,
  not a decision procedure for arbitrary host functions.

$$
\frac{\Sigma;\Gamma\vdash a:\tau\qquad
      \Sigma;\Gamma\vdash b:\sigma\qquad\operatorname{EqCompatible}(\tau,\sigma)}
     {\Sigma;\Gamma\vdash a=b:\mathrm{Boolean}}
$$

For `<`, `<=`, `>` and `>=`, demand both operands and require their non-null
types to be assignable to the same ordered primitive Number or Timestamp.
Null operands throw when evaluated; Text and Entity ordering remain undefined.

Membership uses a Set(σ) or Sequence(σ) range, with EqCompatible(τ,σ) for its
element and candidate types. It compares values; it does not expose an index.

For an ordered primitive p ∈ {Number, Timestamp} and
op ∈ {<, <=, >, >=}:

$$
\frac{\Sigma;\Gamma\vdash_d a:\tau\quad\Sigma;\Gamma\vdash_d b:\sigma
      \quad\tau\preceq p\quad\sigma\preceq p}
     {\Sigma;\Gamma\vdash a\;op\;b:\mathrm{Boolean}}
$$

For K ∈ {Set, Sequence}:

$$
\frac{\Sigma;\Gamma\vdash a:\tau\quad
      \Sigma;\Gamma\vdash_d S:K(\sigma)\quad
      \operatorname{EqCompatible}(\tau,\sigma)}
     {\Sigma;\Gamma\vdash a\;\mathrm{in}\;S:\mathrm{Boolean}}
$$

`not P`, `P and Q`, `P or Q` and `P implies Q` require Boolean-compatible
operands after non-null demand (including Boolean literals) and return Boolean.
They are reference
conditions, not three-valued cognitive-state conditions.

$$
\frac{\Sigma;\Gamma\vdash_d P:\tau\quad\tau\preceq\mathrm{Boolean}}
     {\Sigma;\Gamma\vdash\mathrm{not}\;P:\mathrm{Boolean}}
$$

For op ∈ {and, or, implies}:

$$
\frac{\Sigma;\Gamma\vdash_d P:\tau\quad\Sigma;\Gamma\vdash_d Q:\sigma
      \quad\tau\preceq\mathrm{Boolean}\quad\sigma\preceq\mathrm{Boolean}}
     {\Sigma;\Gamma\vdash P\;op\;Q:\mathrm{Boolean}}
$$

## 9. Scope judgments for sources and steps

Maintain an outer Γ and a local binding map Δ. The expression scope is Γ ⊕ Δ,
where local names override enclosing names. `root` is reserved and cannot be
bound. A new local name must be fresh in Δ; it may shadow a name in Γ.

For an ordered source list:

$$
\frac{
 \Sigma;\Gamma\oplus\Delta\vdash_d S:\operatorname{Set}(\tau)
 \qquad x\notin\operatorname{dom}(\Delta)
}{
 \Sigma;\Gamma\mid\Delta\vdash\mathrm{from}\ S\ \mathrm{as}\ x
   \Rightarrow\Delta[x:\tau]
}
$$

The source is checked before x is introduced. Multiple sources are checked
left-to-right using the resulting Δ. A nullable Set source demands presence and
may throw; a Sequence or nullable Entity never becomes a Set source. Null is
not an empty range.

For a `let` step:

$$
\frac{
 \Sigma;\Gamma\oplus\Delta\vdash e:\tau
 \qquad x\notin\operatorname{dom}(\Delta)
}{
 \Sigma;\Gamma\mid\Delta\vdash\mathrm{let}\ x=e
   \Rightarrow\Delta[x:\tau]
}
$$

For a `where` step:

$$
\frac{\Sigma;\Gamma\oplus\Delta\vdash_d P:\sigma\qquad
      \sigma\preceq\mathrm{Boolean}}
     {\Sigma;\Gamma\mid\Delta\vdash\mathrm{where}\ P\Rightarrow\Delta}
$$

Source/step lists compose these judgments in written order. `where` preserves
the type environment; it filters runtime bindings but performs no automatic
type refinement.

## 10. Projection and complete queries

Write Σ;Γ ⊢projection π : τ for a projection's output type. For a bare
expression, this is its inferred type. For named expressions:

$$
\frac{\Sigma;\Gamma\vdash e_i:\tau_i\;(1\le i\le n)\qquad
      a_i\text{ pairwise distinct}\qquad n\ge1}
     {\Sigma;\Gamma\vdash_{projection}
       e_1\ \mathrm{as}\ a_1,\ldots,e_n\ \mathrm{as}\ a_n:
       \operatorname{Record}\{a_i:\tau_i\}_{i=1}^{n}}
$$

Let sources C and steps D transform the empty local scope into Δ_f. For mode m,
let R_all(τ) = Set(τ) and R_single(τ) = τ. The concrete keywords are `select` for
all and `select!` for single. Then:

$$
\frac{
 \Sigma;\Gamma\mid\varnothing\vdash C;D\Rightarrow\Delta_f
 \qquad\Sigma;\Gamma\oplus\Delta_f\vdash_{projection}\pi:\tau
}{
 \Sigma;\Gamma\vdash
   \mathrm{select}_{m}\ \pi\ \mathrm{from}\ C\ D:
   R_m(\tau)
}
$$

A single-result selection does not prove cardinality statically. `select!`
returns the sole distinct projected value or raises CardinalityFailure for zero
or multiple values. Its result may itself be nullable; exactly one projected
null is one value and succeeds. It never chooses the first source binding.

The projection is checked last even though printed first. A nested query uses
the current Γ ⊕ Δ as its outer environment and begins with its own empty local
scope. Its locals do not leak back to the enclosing query.

## 11. Existence and bounded quantification

$$
\frac{\Sigma;\Gamma\vdash_d Q:\operatorname{Set}(\tau)}
     {\Sigma;\Gamma\vdash\mathrm{exists}(Q):\mathrm{Boolean}}
\qquad
\frac{\Sigma;\Gamma\vdash_d Q:\operatorname{Set}(\tau)}
     {\Sigma;\Gamma\vdash\mathrm{exist!}(Q):\mathrm{Boolean}}
$$

`exists!` is a spelling alias of `exist!`; both use the UniqueResult AST mode.
Ordinary exists uses NonEmptyResult. Q is any set-valued expression, including
a query or a variable storing a query result. A non-set argument is a future
checker diagnostic. A single selection projecting a Person is therefore invalid
here; one projecting a Set may be valid because the argument type is what
matters. The parser preserves the expression without deciding its type.

For K equal to Set or Sequence, and quantifier q equal to exists or every:

$$
\frac{
 \Sigma;\Gamma\vdash_d S:K(\tau)
 \qquad\Sigma;\Gamma[x:\tau]\vdash_d P:\sigma
 \qquad\sigma\preceq\mathrm{Boolean}
}{
 \Sigma;\Gamma\vdash q\ x\ \mathrm{in}\ S\ \{P\}:\mathrm{Boolean}
}
$$

The collection is checked outside the new binder. Its body may shadow an
enclosing name but does not introduce a name in the enclosing scope.

## 12. Cardinality operations and top-level definitions

For K equal to Set or Sequence:

$$
\frac{\Sigma;\Gamma\vdash_d S:K(\tau)}
     {\Sigma;\Gamma\vdash\mathrm{count}(S):\mathrm{Number}}
\qquad
\frac{\Sigma;\Gamma\vdash_d S:K(\tau)}
     {\Sigma;\Gamma\vdash\mathrm{only}(S):\tau}
$$

$$
\frac{\Sigma;\Gamma\vdash_d S:\operatorname{Sequence}(\tau)}
     {\Sigma;\Gamma\vdash\mathrm{first}(S):\operatorname{Optional}(\tau)}
$$

$$
\frac{\Sigma;\Gamma\vdash_d S:\operatorname{Sequence}(\tau)\qquad
      \Sigma;\Gamma\vdash_d i:\sigma\qquad\sigma\preceq\mathrm{Number}}
     {\Sigma;\Gamma\vdash\mathrm{at}(S,i):\operatorname{Optional}(\tau)}
$$

`only` does not statically establish cardinality, and Number typing does not
establish that an `at` index is integral. Runtime checks are explicit in the
evaluation contract.

Top-level definitions use the same nonrecursive extension rule as `let`, with
a separate initially empty definition scope. Their right-hand side can be a
complete ordinary or single-result query, since a semicolon delimits it. The final expression is checked
after all definitions. There is exactly one final result expression per program. For example:

```text
let people = select p from root.people as p;
let alice = select! p from people as p where p.name = "alice";
alice.city
```

Here people has type Set(Person), alice has type Person, and the final expression
has type Text. The second binding may fail cardinality. Stored query results are
runtime values for this evaluation, not persistent views or AST quotations.

## 13. Diagnostics and boundary

Static diagnostics distinguish unknown names/fields/branches, wrong field owners,
non-callable types, unknown/missing/duplicate arguments, wrong argument types,
duplicate local names or output labels, non-Set query sources, non-Boolean
conditions, invalid comparisons, unknown fields after either access operator,
non-variant or nonexhaustive matches, duplicate/unknown match arms, unreachable
fallbacks and invalid timestamp/text literals. Nullable field traversal is now
accepted with a possible MissingValue failure, rather than rejected statically.
Unsupported backend lowering is separately diagnosed after checking.

No rule above asserts world truth, lookup existence, source accessibility,
mental representation, belief consistency or task success. Information-language
questions and fragments have their own kinds outside this standalone grammar.

