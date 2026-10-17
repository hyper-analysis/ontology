# Restricted PostgreSQL query backend

The backend is independent of views. [SQL.Syntax](../src/SQL/Syntax.hs) describes
SQL values, conditions, JSON expressions and queries;
[SQL.Render](../src/SQL/Render.hs) renders them. 
The [O-SQL checker/compiler](o-sql/compiler.md) constructs the same target AST directly.

The library exposes SQL.Syntax, SQL.Render, SQL.Reference, SQL.Query,
SQL.Validate, Ontology.Relational, Ontology.Postgres, Postgres.Physical and
Postgres.Mapping alongside the ontology and O-SQL parser/checker/compiler.

## Physical table and column references

[SQL.Reference](../src/SQL/Reference.hs) has opaque TableRef, TableUse and
ColumnUse values. A TableRef contains a physical identifier and its column
catalog; TableUse binds that table to an alias. columnReference accepts only a
column in that table's catalog. It retains the table occurrence, not just the
column's spelling. Different aliases can bind the same table for self-joins.

[Postgres.Mapping](../src/Postgres/Mapping.hs) constructs those references from
the existing generated PgSchema:

```haskell
bindAt            :: PgSchema -> SemanticOrigin -> Alias -> Either String BoundTable
binding           :: BoundTable -> TableUse
columnAt          :: BoundTable -> Path -> Either String Value
presenceAt        :: BoundTable -> Path -> Either String Value
ownerCondition    :: BoundTable -> BoundTable -> Either String Expr
referenceCondition :: BoundTable -> Path -> BoundTable -> Either String Expr
```

The schematic signatures omit module qualifiers. Paths passed to columnAt,
presenceAt and referenceCondition are relative to the selected physical table's
semantic origin. bindAt finds the containing table; it does not inspect rows.
Owner and reference joins use generated foreign-key metadata, checking source,
target and corresponding key columns. No view or projection is constructed.

For an optional mentor field:

```haskell
flag <- Mapping.presenceAt resident [Field "mentor"]
let present = SQL.Equals flag (SQL.BoolValue True)
```

The physical column may be `__present_mentor`, but its name is obtained from
pgPresenceBindings. A self-reference binds the target table under a different
alias and uses referenceCondition for the foreign-key equality. Table numbers,
column spelling and storage IDs are not reconstructed from strings.

The lower-level tableReference builder also accepts a trusted physical catalog
for hand-built SQL/DDL fixtures. Such a reference certifies membership in that
catalog, not existence in a connected database. Current physical identifiers are
unqualified names interpreted under the caller's search_path.

## Query structures

The existing Query and ValueQuery forms continue to serve the prepared-view
compiler. The general form is:

```haskell
SelectQuery
  { queryOutputs  :: NonEmpty Output
  , querySource   :: Maybe From
  , queryWhere    :: Expr
  , queryDistinct :: Bool
  , queryOrderBy  :: [Value]
  }

Output Name Value

Stored TableUse
Derived Alias Correlation Query
Cross From From
Join JoinKind From From Expr
JsonItems Alias Value
JsonPairs Alias Value
```

JoinKind is InnerJoin or LeftJoin. A derived source explicitly records
Independent or Lateral correlation. An independent source cannot refer to an
earlier sibling in the same FROM tree; a lateral source can. Ancestor query
bindings remain available for correlated subqueries.

JsonItems and JsonPairs expose jsonb_array_elements and jsonb_each as checked
value or key/value sources. Their arguments can refer to preceding sources,
following PostgreSQL table-function correlation.

Named outputs let a derived query expose checked OutputColumn references.
RowValue denotes a bound row/composite value, so JsonScalar (RowValue alias)
can use to_jsonb without exposing unselected storage columns. A query that has
no source still has a projection and condition; it can construct a scalar,
record, aggregate, or an explicitly empty result.

There is no raw SQL constructor or limit field. Identifiers and literals are
quoted by the renderer; values can also be bound through numbered parameters.

## Values, conditions and JSON primitives

Values now include:

- BoundColumn and OutputColumn for physical and derived references;
- CaseValue, CastValue and ConditionValue;
- JsonValue for embedding a JSON expression in a scalar SQL position;
- ScalarQuery for a one-column scalar subquery;
- CountRows, CountValue, CountDistinct and JsonAggregate;
- JsonElement and Coalesce;
- DecimalValue and explicitly typed FailureValue;
- FunctionValue, JsonField, JsonText, JsonLength and JsonArrayValues;
- JsonObjectAggregate and BoolAggregate for finite runtime values/quantifiers.

Conditions add ordered Compare, NullSafeEquals (`IS NOT DISTINCT FROM`),
BooleanValue and ExistsQuery. These express PostgreSQL conditions; native
SQL AND/OR do not establish O-SQL's ordered short-circuit contract. A compiler
requiring that behavior must lower it deliberately, for example with CaseValue.

The existing JsonObject, JsonCase, JsonNullable, JsonOne, JsonArray, JsonMerge
and JsonNull constructors remain. Heterogeneous source match arms can each
construct JSONB; no common source-level record shape is imposed.

JsonOne still means at most one SQL result, with zero mapped to JSON null and
multiple rows producing PostgreSQL's cardinality error. It is not select!.
JsonArray on a general query aggregates its one projected column and maps an
empty result to `[]`. DISTINCT happens inside that source query before packing.
When ordering a general JsonArray, ordering expressions must be projected;
the renderer puts their corresponding derived columns inside jsonb_agg's
ORDER BY. Explicit JsonAggregate also supports aggregate-local ordering.
Renderer-introduced aliases avoid both source binders and correlated references.

## Scope and shape checking

```haskell
validateQuery      :: Query -> Either String ()
renderCheckedQuery :: Query -> Either String String
```

Use the checked rendering entry point for newly constructed general queries.
Validation checks physical column ownership, bound aliases, derived output
names, duplicate outputs/aliases, lateral visibility, scalar-query arity,
parameter indices and supported projected ordering. New source aliases may not
shadow already visible bindings, a conservative compiler convention.

It is not a complete SQL type checker. PostgreSQL still checks scalar type
compatibility and aggregate legality. Legacy string column references remain
for the existing schema/read compiler; where their source catalog is known,
the checker checks their column names too. The older renderQuery/renderProgram
interfaces remain available for existing callers.

## Cardinality and failures

[SQL.Query](../src/SQL/Query.hs) supplies small AST builders:

```haskell
countQuery :: Alias -> Query -> Query
uniqueQuery :: Alias -> Query -> Expr
exactlyOne :: Name -> Alias -> Alias -> Query -> Either String JsonExpr
```

countQuery counts rows while evaluating their projected row value. It uses
count(to_jsonb(derivedRow)), so a projected SQL null still counts as a row and
required projection work is retained. uniqueQuery compares that count with one.
This differs from CountDistinct, whose PostgreSQL semantics exclude SQL NULL.
For O-SQL set cardinality, first construct a DISTINCT source, then count rows.

exactlyOne aggregates a one-column source once into count/payload, returns its
sole value as JSON, or raises CardinalityFailure for zero/multiple rows. It also
accepts the single projected JSON-null value. Source deduplication is explicit;
the builder does not invent a different equality rule. Its JSON output is useful
at a result-packaging boundary; it is not yet a general typed O-SQL local-value
lowering algorithm.

FailureValue names a closed MissingValue, CardinalityFailure or IntegrityFailure and a return
SqlType. CreateFailureFunction declares the corresponding polymorphic,
VOLATILE PL/pgSQL helper. The helper raises SQLSTATE P0001 with the chosen
failure name, and its typed exemplar lets CASE arms agree on a PostgreSQL type.
Inactive CASE arms do not invoke it. Installing that explicit helper statement
is the caller's responsibility, not a side effect of rendering a query.

These are target mechanisms. The O-SQL compiler now implements checking,
nullable navigation and ordered program evaluation using explicit scalar-function
boundaries. CreateValueFunction describes typed parameters, one query body and
a scalar result. Its PL/pgSQL STABLE rendering prevents SQL-function inlining
and retains the calling snapshot; it has no raw procedure-body escape hatch.
Ordinary ExistsQuery still inherits PostgreSQL EXISTS evaluation behavior;
it is not by itself proof of the stricter source-language evaluation contract.
See [O-SQL compilation](o-sql/compiler.md) for the source interpretation.

## Numbers

SqlNumeric and SqlJsonb extend the target SQL types. DecimalValue stores an
Integer coefficient and Integer decimal exponent and renders an exact numeric
literal without conversion to Double. Existing NumberValue Rational also
renders finite decimal rationals exactly; nonterminating rationals render an
explicit numeric division, subject to PostgreSQL numeric division precision.

The ontology storage interpretation now maps number columns and numeric enum/
literal columns to SqlNumeric, aligning new schemas with O-SQL exact numbers.
SqlDouble remains a general target type for explicit callers. Existing databases
are not migrated automatically, and previously rounded floating-point values
cannot be recovered by changing a column type. O-SQL compilation requires the
matching numeric catalog; source values beyond PostgreSQL precision/range are
explicit UnsupportedLowering diagnostics.

## Executable examples and checks

[test/SQLMain.hs](../test/SQLMain.hs) constructs the medium Resident/Visitor
query directly from generated schema metadata: explicit left joins, optional
mentor, heterogeneous CASE results, DISTINCT, derived rows and to_jsonb. It has
no view/projection dependency and no O-SQL-to-SQL compiler is implied.

The suite checks invalid references/scopes and emits paired expected/actual
PostgreSQL fixtures covering the medium result, general and lateral sources,
array ordering, nulls, aggregates, uniqueness, exactly-one failures, CASE
laziness, exact decimals, quoting and correlated-alias hygiene.

```sh
cabal test ontology-language:sql-backend-test
make test
# Against an explicitly disposable PostgreSQL instance:
ONTOLOGY_TEST_DATABASE=1 make sql-test
```

The shared unit job builds/runs the AST checks; the SQL job executes the emitted
fixtures for the SQL backend and O-SQL compiler. JSON number checks
use Decimal parsing so comparison cannot silently lose numeric precision.

