# O-SQL checking and PostgreSQL compilation

[Language](README.md) · [Typing](typing.md) · [Evaluation](semantics.md) · [SQL target](../sql-backend.md)

The library now has an executable source-to-PostgreSQL path. It checks queries
against the existing ontology, lowers checked expressions into SQL.Syntax and
renders explicit function definitions plus one result query. All 15 published
examples are checked, compiled and executed by the SQL integration suite.

This first implementation prioritizes the specified values and failure behavior.
It materializes sets, maps and intermediate binding environments as JSONB values.
It does not yet optimize a whole O-SQL program into one fused relational SELECT.
There is no independent in-memory O-SQL evaluator yet.

## Public API

```haskell
-- OSQL.Check
checkProgram :: String -> Ontology -> Program -> Either Diagnostic CheckedProgram
resultType :: CheckedProgram -> Type
renderDiagnostic :: Diagnostic -> String

-- OSQL.Compile
compileProgram :: String -> CheckedProgram -> Either LoweringError Compilation
renderCompilation :: Compilation -> String
```

The first String to checkProgram is the ontology's root type name. The String to
compileProgram is a function namespace: 1–24 ASCII letters, digits or underscores.
The names are SQL-quoted, so a leading digit is permitted. Choose a fresh
namespace for each installed compilation, or install it in a fresh schema.
Compilation does not overwrite or delete existing functions.

CheckedProgram is opaque in the public API. The checker derives signatures from
the checked ontology; callers do not supply invented field owners, key signatures
or result types. OSQL.Type exposes the query type algebra, assignability,
equality compatibility, nullable unions and prettyType. OSQL.Syntax remains the
unresolved, located source AST.

A Compilation contains:

```haskell
compilationSchema :: PgSchema
compilationSetup  :: SQL.Program
compilationQuery  :: SQL.Query
compilationType   :: OSQL.Type.Type
```

The schema is the expected catalog, generated through the existing relational
and PostgreSQL interpretations. Setup contains read functions and an explicit
failure helper. The query returns one JSONB result. No table DDL, data update or
installation is a side effect of these pure functions. Use Postgres.Physical
separately to create a database matching compilationSchema.

Static diagnostics carry a code, message and source span. Backend restrictions
produce a separate LoweringError, including UnsupportedLowering. A valid source
program can therefore check successfully while exceeding this backend's exact
representation. Compilation never substitutes null, false or an empty set for
an unsupported operation.

## Command line

From the repository root:

```sh
cabal run osql-compile -- \
  docs/o-sql/examples/roles.ontology Root \
  docs/o-sql/examples/complex-roles.osql report \
  > report.sql
```

The inferred result type goes to stderr; function definitions and the final SQL
query go to stdout. The command exits nonzero for syntax, type or lowering errors.
It does not connect to PostgreSQL. Execute the generated file under the intended
schema's search_path after installing the matching ontology schema and data.
Table/function references are unqualified; keep that search_path/catalog in
place when installing and executing the plan.
The generated functions retain the caller's privileges; they are not
SECURITY DEFINER functions.

Programs currently have no externally supplied lexical-variable interface.
Names come from ordered top-level definitions, query sources/lets, quantifiers
and match payload binders. Root comes from the ontology's stored populations.
Connecting this checked query language to information fragments, questions and
cognitive state remains separate work.

## What the checker resolves

The checker implements the typing sequents for records, root populations,
references, declared keys, maps and alternatives. It checks source scopes before
projections, sources from left to right and steps in written order. Nested
queries can shadow enclosing names; duplicate bindings in one local scope fail.
Top-level definitions are strict, nonrecursive bindings and cannot repeat names.

Literal and enum refinements are retained when checking key/map arguments. The
complete value of each immediate key-marked field is required. Composite keys
use declared labels; a single-key lookup may use its positional form. A record
with key-looking fields remains a record rather than an entity.

Ordinary dot accepts a nullable owner with a possible runtime MissingValue.
Optional dot records the possibility of skipping the rest of the current chain.
Neither operation makes an unknown field valid. Fields on a non-null union must
exist on every possible owner. Application checks every possible callee
signature. Result unions retain different record/scalar/collection shapes.

Match checks declared labels, coverage, local payload scopes and unreachable
fallbacks. Boolean demands, ordered scalar comparisons, structural equality,
membership, set-only query sources, cardinality operations and sequence-only
operations are checked independently of whether a branch will execute.

Timestamp checking validates Gregorian dates, offsets and fractional syntax. It
normalizes to a UTC instant using whole-second calendar arithmetic and retains
the exact fractional digits, without converting the fraction to floating point.

## Runtime values and equality

The compiler uses a private JSONB value algebra. It is a target representation,
not a new O-SQL syntax or ontology:

| Value | Internal information |
| --- | --- |
| Scalar | Primitive family and scalar payload |
| Null | JSON null |
| Record | Literal field names and recursively encoded values |
| Entity | Population name and complete encoded semantic key |
| Set | Canonical distinct array of encoded values |
| Map | Canonical array of encoded key/value entry records |
| Variant | Declared tag name, active branch and encoded payload |

Records have no storage identity. Entity values never contain surrogate IDs;
reference and map-key reads resolve those IDs into complete semantic keys.
Reference-valued keys recursively retain their target population and key.
Sets and maps omit their owning storage location, so their equality is by value.

Canonical arrays sort/deduplicate encoded members using PostgreSQL JSONB
comparison. Encoding primitive families and value constructors prevents a number,
a Boolean, a record and an entity with similar visible JSON from collapsing.
JSONB numeric equality preserves 1 = 1.0. Record field order is immaterial.
Timestamp values pass through timestamptz before encoding, so differing written
offsets for one supported instant compare equal.

Map calls normalize argument labels, then compare the complete encoded argument
record with each stored key. Entity-set calls search that supplied set and
compare semantic keys, so looking up a filtered-out entity returns null. Union
callees dispatch on their actual set population or map argument labels; an empty
callee has no matching entry and returns null. Calls never become host function
execution.

## Evaluation boundaries and failures

CreateValueFunction is a small target primitive: a typed scalar function with
one query body and a RETURN. The renderer emits LANGUAGE plpgsql STABLE. Unlike
a trivial LANGUAGE sql function, this wrapper is not SQL-inlined. PostgreSQL
evaluates its arguments as values before entry. STABLE makes nested database
reads use the calling statement's snapshot.

The lowering equations use those boundaries as follows:

1. Each checked expression denotes a function of an encoded lexical environment.
2. A top-level definition extends the environment with its evaluated value.
   A later function receives that completed environment, including unused values.
3. A query starts with a singleton array containing its outer environment.
4. Each source/let/where is a separate function from an environment array to the
   next environment array. Its input is evaluated before the next stage begins.
5. Sources fully evaluate their set, then extend each environment with its members.
   Let evaluates its expression for every current environment. Where evaluates
   its Boolean and retains matching environments.
6. Projection evaluates every surviving expression, constructs a canonical set,
   and only then decides existence, uniqueness or single-result cardinality.

A false later filter cannot erase an earlier unused failing let. An empty stage
has no per-binding work to run afterwards. Stored query results are encoded
values in the environment, not syntax that is rerun on each variable lookup.

Match passes its scrutinee once to a dispatcher. Postfix stages pass their
receiver once to the next operation. CASE selects the active match/logic/optional
branch, so inactive arms and skipped call arguments do not execute. An executed
null callee or argument still raises MissingValue.

Bounded quantifiers evaluate the complete range and aggregate every demanded
Boolean body. A true existential or false universal witness cannot hide another
member's failure. Within each member, and/or/implies still use lazy CASE arms.

The compiled existence operators inspect completed set values; they do not use
native SQL EXISTS as a shortcut over partial source computations. A singleton
projected null counts as one value. Zero/multiple results for only/select! raise
CardinalityFailure; ordinary missing keyed/map lookups return null.

The explicit failure helper raises SQLSTATE P0001 with MissingValue,
CardinalityFailure or IntegrityFailure as its message. PostgreSQL schema/type
errors, cancellation and resource exhaustion remain technical failures. This
compiler expects a complete database conforming to the generated ontology; it
does not interpret a partial projection as available reference data.

## JSON transport

After evaluation, a separate recursive function removes the private envelopes:

| O-SQL result | JSON transport |
| --- | --- |
| Scalar/null | JSON scalar/null |
| Record | Object of transported fields |
| Set | Array of transported members, with no source ordering guarantee |
| Map | Array of `{key: ..., value: ...}` entries |
| Entity | `{"$entity":"Person","key":{"name":"alice"}}` |
| Variant | `{"$variant":"role","branch":"Resident","value":...}` |

Entity transport terminates at the semantic key, so reference cycles do not
expand into infinite objects. Request fields explicitly when a result should
contain an entity's data. Heterogeneous match results retain their selected
shape; transport adds neither a match-result tag nor missing fields from
inactive arms. A present empty record transports as `{}` and absence as null.

The inferred type distinguishes constructors that plain JSON might otherwise
conflate. Do not infer Set/Sequence or Entity/Record type from JSON shape alone.
Clients requiring exact Number values must preserve JSON decimal precision.

## Storage alignment and limits

Ontology number atoms, numeric literals and enum columns now use PostgreSQL
numeric, including map keys and semantic identity keys. This aligns new schemas
with O-SQL's exact finite-decimal semantics. Existing double precision databases
are not migrated by this compiler. Install/migrate a matching catalog before
executing generated queries; precision already lost in floating-point data or
an upstream JSON client cannot be reconstructed.

The checker accepts the source language's exact number/timestamp domain. The
backend reports UnsupportedLowering for nonzero decimals beyond PostgreSQL
numeric's precision/range, and timestamp literals requiring more than six
fractional digits after removing trailing zeros or an unsupported UTC boundary.
It does not silently round them.

Other explicit storage restrictions are ordered sequences without a persisted
ordinal, optional root populations without a root-presence marker, cyclic
semantic reference keys, aliased identity populations stored in separate tables
and mixed-family enums lacking a single physical scalar interpretation. These
are backend/catalog restrictions, not new source-language constraints.

Materializing whole population designators, owned values and intermediate arrays
can be expensive. The first compiler is suitable for semantic execution and
small/medium fixtures; large datasets need profiling, demand-specific storage
reads and proven-safe relational fusion. There is no resource cutoff disguised
as an empty or complete query result.

## Verification

[test/OSQLCompileMain.hs](../../test/OSQLCompileMain.hs) checks static diagnostics,
source locations, nullable results, heterogeneous unions and backend boundaries.
It emits independently expected result/failure fixtures, including all published
examples and a separate ontology with nested reference keys, structured map
parameters and union callees. Tests choose different SQL IDs from semantic keys.

The integration suite executes ordered-let failures, lazy branches, strict
quantification, exact numeric storage, identity, map entries, set deduplication,
cardinality and nested correlation. O-SQL fixtures explicitly compare their
Set/Map-only transport arrays without imposing enumeration order. Existing
prepared-view fixtures continue to compare arrays in order. Scalar comparison
keeps Booleans distinct from numbers and parses decimals exactly.

```sh
cabal test ontology-language:osql-compiler-test
make test
ONTOLOGY_TEST_DATABASE=1 make sql-test
```

