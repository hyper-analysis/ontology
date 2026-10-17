# O-SQL: ontology selections and queries

**Status: implemented parser, ontology-aware checker and PostgreSQL compiler.**
[OSQL.Syntax](../../src/OSQL/Syntax.hs) and OSQL.Parser provide the located source
frontend. OSQL.Check derives query types from the checked ontology; OSQL.Compile
lowers checked programs into the [view-independent SQL backend](../sql-backend.md).
All 15 published examples execute in the SQL integration suite. The independent
in-memory evaluator and information/cognitive integration remain future work.
See [compiler API, execution boundaries and limits](compiler.md).

| Document | Contract |
| --- | --- |
| [Concrete BNF](grammar.bnf) | Accepted sentence structure |
| [Checker and SQL compiler](compiler.md) | Implemented API, CLI, runtime representation, evaluation order and backend limits |
| [Parser and source AST](parser.md) | Implemented API, CLI, locations and syntax/checking boundary |
| [Typing sequents](typing.md) | Scope, types, key signatures and clause checking |
| [Evaluation](semantics.md) | Values, optionality, identity, ordered steps and failures |
| [Examples](examples.md) | Complete query files with hand-derived types |

This draft is edited in place. It introduces no release compatibility scheme or
selectable language/combination profiles.

## 1. Purpose and separation

An O-SQL expression describes a selection or computed result over an ontology
instance. Its checked structure can have two interpretations:

```text
.ontology source -> checked ontology
                              |
O-SQL source -> parse -> resolve/check -> checked expression
                                           |          |
                                  direct evaluation   SQL lowering
```

Interpretations share object identity, bindings, types, cardinality and failure
semantics. Database table names and surrogate IDs do not occur in the language.

## 2. Ontology dependence and `root`

The ontology supplies fields, reference targets, alternatives, partial-map
signatures and semantic keys. The query checker derives these signatures; the
author does not supply a schema node ID or duplicate a field's result type.

For example:

```text
type Person = { key name: string; city: string; };
type Directory = { people: Person[]; };
```

`root` denotes the bound Directory instance, and `root.people` denotes its Person
population. Population members and `Ref<Person>` values are exposed to queries
as Person object designators, represented semantically by their population and
declared key. An object designator permits subsequent field selection; it is not
a request to eagerly copy the complete object graph.

Ordinary by-value records retain value/ownership semantics. A nested record does
not gain independent entity identity merely because it has a name or key
annotations in its type. SQL storage identities remain private to storage.

## 3. Selection and key lookup

```text
root.people
root.people("alice")
root.people(name: "alice")
root.people("alice").city
```

These have types `Set<Person>`, `Optional<Person>`, `Optional<Person>` and `Text`.
The two lookup forms are equivalent for the single declared key `name`.

The local variable in the following program is an alias for an evaluated
selection result. It is not an unexplained ontology-object ID:

```text
let alice = root.people("alice");
alice.city
```

For a composite key, every component is named:

```text
root.sites(country: "FR", code: 42)
```

Argument order is irrelevant. Positional application is available only for a
signature with one component. Mixed positional/named arguments, duplicate names,
missing names, extra names and wrong argument types are rejected. Key lookup
returns absence when no member of the supplied set has the key. A declared key
guarantees uniqueness in a valid instance, not existence.

Lookup applies to `Set<Entity<E>>`, including a query-produced subset of that
entity population. It searches that set, not the entire population. A set of
projection records has no implicit entity-key lookup capability. Integrity
`unique` annotations do not by themselves declare an object's identity key.

## 4. Fields, null and alternatives

```text
person.city
person.teacher
person.teacher.city
person.teacher?.city
root.people("alice")?.city
```

The subject's type resolves a field name. Reference-valued fields produce target
object designators; the checked selection retains the reference-site traversal
and its provenance. There is no user-supplied `OntologyField node name` in source.
Collections are not implicitly traversed by dot selection.

A missing lookup or optional field returns `null` successfully. Merely binding,
returning or comparing that value does not throw. Ordinary `.` requires a present
receiver and raises MissingValue if it is null. Selecting an optional field from
a present object can itself return null without error. Unknown fields remain
static errors, including after `?.`.

`?.` short-circuits a continuous postfix chain when its receiver is null:

```text
root.people("alice")?.teacher?.name
person.teacher?.teacher.name
person.teacher?.teacher?.name
```

The first protects both optional receivers. In the second, a missing teacher
skips the suffix; a present teacher with a null second teacher still makes
`.name` throw. The third protects both teacher accesses. Calls in a skipped
suffix and their arguments are not evaluated. Optional-call `?.()` and indexing
syntax are outside this core.

Field names are literal labels. Computed attributes such as `a.(expression)` or
`a[expression]` are banned. A parenthesized expression cannot be followed by any
field, optional-field or call suffix: `(a?.b).c` and `(select ...)(key)` are
syntax errors. Bind such a grouped query/result to a variable before navigating or
applying it. Parentheses still group conditions and delimit nested queries;
they do not create another form of attribute selection.

`Optional<T>` abbreviates `T | Null`. These are nullable query values, not nested
Some/None wrappers: adding optionality twice has the same type and null value.
A present record with absent fields remains a record, distinct from null.

A partial ontology map is applied by its declared signature:

```text
person.schooling(year: 2026, track: "science")
person.schooling(year: 2026, track: "science")?.label
```

A missing entry returns null. A one-parameter map permits the single positional
abbreviation. `entries(map)` enumerates finite stored entries as records with
`key` and `value` fields; `key` contains the named arguments:

```text
select entry.key.year as year, entry.value.label as label
from entries(person.schooling) as entry
```

Operations requiring a map, collection, Boolean, ordered scalar or active
alternative demand a non-null value when executed. They do not reinterpret null
as an empty collection or false. Nullable inputs with a suitable non-null type
are accepted with a possible MissingValue failure; an unrelated non-null type
is still rejected statically. Equality is explicitly null-aware:

```text
person.teacher = null
not (person.teacher = null)
```

### Match expressions

`match` evaluates an alternative, binds its active payload and evaluates only
that arm:

```text
match person.role {
    Resident resident => resident.city;
    Visitor visitor => { destination: visitor.destination };
}
```

Here the result type is `Text | {destination: Text}`. Arms may return different
kinds of query values: records with different fields, entities, collections,
scalars or null. Their union is a query type; no ontology declaration or common
result shape is required. Equal arm types collapse in that union. The input's
tag is not automatically attached to an arm's result; include a distinguishing
field explicitly when the result needs one.

Every declared branch must be covered exactly once, or uncovered branches must
be handled by a final `_ => expression;` arm. Unknown/duplicate branches and
unreachable fallbacks are static errors. A fallback has no payload binder.
Each named arm has its own scope; its binder may shadow an enclosing name and
does not escape. The scrutinee is evaluated once. A null scrutinee throws
MissingValue, including with a fallback; `_` covers alternative branches, not
null or evaluation failures. All arms are checked even though only one executes.

```text
match person.role {
    Resident resident => resident.city;
    _ => null;
}
```

Each arm ends with a semicolon. An arm can return a complete query directly, or
a parenthesized query as in the [complex example](examples/complex-roles.osql).
`branch`, `present` and `require` are not query builtins; `match`, null equality
and ordinary/optional field access supply their relevant behavior.

## 5. SQL-shaped query sentences

```text
select person from root.people as person where person.city = "Paris"
```

A query is one expression. Newlines are whitespace. There is no outer `query`
block and no `yield` keyword. A query begins with `select` or `select!`, then one
`from` list and any number of `let` and `where` steps in written order.

`select` returns the set of distinct projected values. `select!` requires that
same set to contain exactly one value: return it directly, or raise
CardinalityFailure for zero or multiple distinct values. This is not first-match
selection and adds no `limit` clause. Singleness is checked after projection and
deduplication, not by counting source rows.

```text
select! person from root.people as person where person.name = "alice"
```

`exist!(select ...)` returns true exactly when the query's distinct result set
has cardinality one. Zero or multiple values return false without a cardinality
failure. `exists!` is an accepted spelling alias. Ordinary `exists(select ...)`
still means at least one result. Both wrappers accept any set-valued expression,
including a query or a variable holding its result: `exist!(people)`. A non-set
argument is a type diagnostic. Their argument expressions can still fail
for an executed invalid operation. There is no unique bounded-quantifier syntax.

```text
exist!(select person.city from root.people as person)
```

Two people in the same city produce one distinct city, so the last predicate is
true for that population; selecting both people would make it false.

```text
select person as person, earlyLessons as lessons
from root.people as person
let earlyLessons = (
    select lesson
    from person.lessons as lesson
    where lesson.startsAt < noon
)
where person.city = "Paris"
where count(earlyLessons) >= 2
```

Each source has an explicit alias. Later sources can use earlier source aliases:

```text
select person as person, lesson as lesson
from root.people as person, person.lessons as lesson
where lesson.startsAt < noon
```

`from` ranges over sets. A binding is introduced for each member, without
choosing an arbitrary first match. Sequence iteration is not silently converted
to set iteration. Additional source bindings occur in the initial comma-separated
`from` list; source expressions can contain parenthesized correlated queries.

Nested queries are parenthesized. This makes it explicit which query owns a
following `let` or `where`. Their source/step expressions can use enclosing
bindings; their local bindings do not escape.

## 6. Ordered `let` and `where`

The evaluation/checking order is:

```text
from bindings -> let/where steps in written order -> select projection
```

Although written first, the projection is checked in the final clause scope.
A `let` can bind a scalar, object designator, record, map, nullable value,
alternative, union, set or sequence. Query results are ordinary binding values:

```text
let people = select person from root.people as person where person.city = "Paris";
let alice = select! person from people as person where person.name = "alice";
alice.city
```

Top-level queries need no extra wrapper because the semicolon delimits each
binding. Inside a query step, use `let lessons = (select ...)` to delimit a nested
query. These bindings store the evaluated result during one evaluation; they do
not create persistent database objects or quote unevaluated syntax. A `let`
computes a value for each current binding; it does not add a row to the ontology
or mutate data.

```text
select teacherCity
from root.people as person
let teacher = person.teacher
where not (teacher = null)
let teacherCity = teacher.city
```

Only bindings passing the null filter reach `teacher.city`. Moving the final
`let` before the filter can change success into failure and is not generally a
valid optimization. `let` is strict even when its name is unused later. This is
an operational commitment of this language, stronger than ordinary SQL's freedom
to reorder expressions. A backend must preserve it or report unsupported
lowering; it cannot silently adopt SQL null/error behavior.

Names are nonrecursive. A right-hand side is checked/evaluated before its new
binding is introduced. A name cannot be introduced twice in one query or one
top-level definition scope. A nested query creates a fresh local scope and may
shadow an enclosing name. Projection labels are output labels, not bindings.

## 7. Projection shape and set semantics

```text
select person from root.people as person
select person.city from root.people as person
select person.city as city from root.people as person
select person.name as name, person.city as city from root.people as person
```

Their result types are:

```text
Set<Person>
Set<Text>
Set<{ city: Text }>
Set<{ name: Text; city: Text }>
```

A bare single projection yields its value. One or more explicitly named
projections yield a record. Multiple projections must all be named; there is no
inferred column naming or mixed named/unnamed form. Duplicate labels are errors.
Record construction is also an expression:

```text
select { person: person, city: person.city } from root.people as person
```

Queries return sets. Equal projected results collapse, so selecting cities alone
can discard which people supplied them. Include distinguishing entities or map
arguments in the projection when that distinction is required. SQL's default bag
semantics and physical row order are not the language semantics.

## 8. Conditions, quantification and finite sequence operations

Conditions use equality, ordered comparison, membership, `not`, `and`, `or` and
`implies`. Ordering is defined for numbers and timestamps. Entity equality uses
semantic identity; records/sets/sequences use the equality of their components.
Null-aware equality and errors are specified in [evaluation](semantics.md).

```text
exists (select lesson from person.lessons as lesson where lesson.startsAt < noon)
exists lesson in person.lessons { lesson.startsAt < noon }
every lesson in person.lessons { lesson.startsAt < noon }
```

The first two express existence, with query-existence and bounded-quantifier
syntax respectively. The unique query predicate `exist!` is specified in section 5. Quantifiers accept sets or sequences and return Boolean.
Their local name is in scope only in the body, not in their range. Universal
quantification over an empty range is true; existential quantification is false.

```text
count(collection)
only(collection)
first(sequence)
at(sequence, index)
```

`count` and `only` accept sets or sequences. `only` demands cardinality one.
`first` and `at` accept only sequences and return optional values. Positions are
zero-based. A nonintegral numeric index is an error; an integral out-of-range
index, including a negative index, gives absence.

Sorting, pagination, general sequence comprehensions, bags, aggregation suites,
mutation and arbitrary host-language calls are outside this core. Set filters
and maps use the canonical `select ... from ... where ...` sentence. No second
set-comprehension grammar is required.

## 9. Programs, literals and concrete syntax

An input file contains zero or more top-level `let name = expression;`
definitions followed by one result expression, optionally terminated by `;`.
Definitions bind values in order and can also bind a complete query expression.

Text literals use double quotes with JSON escapes. Numbers are exact finite
decimal values, including scientific notation. Booleans are `true` and `false`;
`null` is the explicit absence literal.
Timestamps use an offset-bearing RFC 3339-style literal constructor:

```text
timestamp("2026-10-17T12:00:00+02:00")
```

This core accepts four-digit years 0001–9999, valid Gregorian dates, uppercase
`T` and `Z`, seconds 00–59 and an optional decimal fraction. A known offset is
mandatory: `Z` or `±HH:MM` with hours 00–23 and minutes 00–59; the unknown-offset
marker `-00:00` is rejected. Leap-second literals and timezone names are outside
this core. Fractions retain their exact precision.

Timestamp comparison/equality uses instants, independent of the written offset.
Invalid timestamp literals are diagnostics, not missing data. NaN and infinity
are not numeric values. Text equality compares Unicode scalar sequences without
implicit case folding or normalization; unpaired surrogate escapes and U+0000
are rejected to retain a common text domain with PostgreSQL.

Identifiers use a Unicode letter or underscore followed by Unicode letters,
decimal digits or underscores. Keywords are case-sensitive lowercase words. The bang in `select!`, `exist!`
and `exists!` is adjacent to its keyword; an intervening space/comment is rejected.
Keywords are reserved as local names, but may be ontology field names, named
argument labels, record labels, branch labels or projection labels in those
explicit positions. The standalone `_` is reserved for the match fallback and
cannot bind a name; longer names beginning with underscore remain identifiers.
Comments start with `//` and continue to the line end. There are no block comments,
implicit statement boundaries at newlines, chained comparisons, trailing commas
or arbitrary function-call forms. Full productions are in [grammar.bnf](grammar.bnf).

Lexing uses maximal munch. Ignored whitespace is space, tab, carriage return or
line feed. `NUMBER` has this regular expression (digits here are ASCII):

```text
-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
```

There is no separate unary minus operator. `IDENT` uses Unicode categories
Letter (`L*`) and Decimal_Number (`Nd`) as described above. `STRING` follows
JSON's double-quoted string/escape syntax, subject to the scalar-value and NUL
restrictions above. A Unicode surrogate escape pair denotes its single scalar.

## 10. Integration and precision boundary

`OSQL.Syntax` is the located source AST. `OSQL.Check` checks it against the
ontology and produces an opaque checked program. `OSQL.Compile` lowers that
program through the independent SQL backend; see [the compiler API](compiler.md).
The source grammar remains independent of centered views.

Source evaluation retains the null, failure, clause-order, singleness,
quantification and set semantics specified here and in [evaluation](semantics.md).
The independent in-memory query evaluator remains pending.

