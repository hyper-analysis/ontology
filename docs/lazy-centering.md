# Lazy, field-level centering

The new centering definition has three independent parts:

```text
checked ontology -> finite semantic relation graph
semantic graph + address -> lazy centered schema
lazy centered schema + depth -> finite observation
```

`Ontology.Center.Graph`, `Ontology.Center.Lazy`, and `Ontology.Center.Observe`
implement these parts. The older `Ontology.Center` module is retained only as
historical reference with its original regression tests. It does not define the
new API: in particular, its enclosing-population identity must not be mistaken
for the identity of every nested value.

There is no SQL dependency, database query, pagination policy or UI projection
policy in these modules. This increment does not modify the existing storage
compiler or its SQL output.

## What a point identifies

An `Address` identifies a SCHEMA OCCURRENCE:

```haskell
population "Person"
within (population "Person") [R.Field "employment", R.Field "job"]
within (population "Person") [R.Field "jobs", R.Elements]
```

It is not a database row ID. `Site.siteKey` specifies the key components needed
to bind a runtime occurrence later. Equal values at different addresses do not
become the same object. Two equal collection members can have distinct
occurrence components. Only an explicit reference crosses to a canonical
population.

Focusing `Person.job` when its type is `Ref<Job>` focuses the pointer occurrence
first. Its `Reference "Job"` edge reaches the canonical Job population. Incoming
references belong to that population, not indiscriminately to every by-value
field under Person.

Alternative branches preserve a canonical identity only while extending that
identity directly. For example, the Student branch of the Person population
retains Person identity. A by-value Payment field inside Person does not acquire
Person identity merely because its rows inherit the Person key.

## Why the graph reads the checked ontology

Ordinary object fields are flattened in `Relational.Row`. Inferring them only
from column prefixes loses an empty record such as `flag?: {}` entirely.

The graph therefore reads the checked ontology to retain every semantic field
boundary, including scalars, empty records, collection values and their members,
map arguments/results, alternative tags and branches. Each site also carries
its independently lowered `Relational.Row` for later storage/query integration.
No SQL schema is inspected or reverse-engineered.

The graph expands definitions by value and stops at Ref. A validated finite
graph is built first; reference edges link existing canonical population roots.
Recursive by-value definitions and missing reference endpoints are errors.
Existing root/alias resolution restrictions are unchanged.

## Primitive inverse cases

| Relation | Forward bound | Inverse bound from an existing child |
| --- | --- | --- |
| required value field | exactly one | exactly one owner |
| optional value field | at most one | exactly one owner |
| collection to member occurrence | many | exactly one collection |
| map to unbound entry | many | exactly one map |
| entry to argument occurrence | exactly one | exactly one entry |
| alternative to selected branch | at most one | exactly one alternative |
| explicit Ref to entity | exactly one for a present pointer | generally many reference occurrences |

Map uniqueness applies to the complete owner-plus-argument tuple. It is not a
global inverse-uniqueness proof for one argument. Collection distinctness also
does not imply that a referenced entity has only one incoming owner globally.

An explicit unique scalar reference without an intervening map/collection key
can bound its inverse by at-most-one. Other reference inverses remain
conservatively plural pending a more general scoped uniqueness prover.

Presence and tag conditions carry full addresses. Map and occurrence key
components retain the address at which they were introduced. Reversing an edge
does not discard any of this information. Map-key references are indexed only
at their argument occurrence, not again at every descendant that inherits the
key.

## Relation algebra

Relations retain their endpoints and ordered primitive traversals:

```haskell
identity :: Address -> Relation
forward  :: Edge -> Relation
inverse  :: Relation -> Relation
compose  :: Relation -> Relation -> Either String Relation
```

Composition checks that the intermediate addresses match. Inversion reverses
the sequence and flips every direction:

```text
inverse (a ; b) = inverse b ; inverse a
inverse (inverse a) = a
```

There is intentionally NO cancellation rule `a ; inverse a = identity`:
relations can be many-valued, so their converse need not be an inverse function.

`ownerRoute` describes the full structural path from a population to a value.
`incomingOwnerRoutes` reverses complete incoming paths. For example, an incoming
Job reference nested inside a company's departments and assignments keeps that
entire provenance rather than exposing only an invented reverse field name.

These are relation descriptions, not materialized joins or data filters.

## Lazy definition

```haskell
data Centered = Centered
  { here     :: Site
  , outgoing :: [Connection]
  , incoming :: [Connection]
  }

data Connection = Connection
  { via  :: Relation
  , next :: Centered
  }
```

A non-strict map ties each connection to the centered value for its endpoint.
Reference cycles and ordinary containment followed by its converse may unfold
forever. This is intentional and productive: `center` does not recursively
materialize an infinite tree. No `Eq` or `Show` instance traverses Centered.

```haskell
graph   <- world "TutoringCompany" checkedOntology
focused <- center graph (Address "Person"
  [R.Branch "enrollmentType" "Student", R.Field "address", R.Field "city"])
view    <- observeDepth 2 focused
```

`observeDepth 0` returns the selected node's shallow metadata and an explicit
`Cutoff`; it does not evaluate either connection list. It therefore does not
confuse 'not explored' with 'has no relations'. A finite depth over this finite
adjacency graph yields a finite schema observation, although breadth may still
make large depths expensive. Negative depths are rejected.

Depth counts primitive edges, including both field ownership and dereferencing.
Cycle avoidance, total node budgets, relation filters, and presentation-specific
selectors are deliberately not imposed by the definition. Runtime result row
limits and pagination are a separate future layer as well.

## Inspect an actual field

With GHC, Megaparsec, mtl and scientific available, from the repository root:

```sh
runghc -isrc \
  app/CenterMain.hs \
  examples/tutoring-company.ontology \
  TutoringCompany Person 1 branch:enrollmentType=Student address city
```

Or run the packaged `ontology-center` executable with the same arguments.
Path tokens are ordinary field names, `field:NAME`, `elements`, `entries`,
`arg:NAME`, `tag:NAME`, and `branch:TAG=LABEL`. The prefix form can disambiguate
fields literally named `elements` or `entries`.

CI compiles this executable and the independent centering test suite with
`-Wall -Werror`. Tests cover every primitive relation case, qualified inherited
keys, alias reuse by value, empty/optional fields, inverse laws, full ownership
paths, self-reference productivity, and cutoff non-evaluation. They also center
an ordinary nested field of the real tutoring ontology. The existing ontology
and SQL installation suite runs unchanged alongside it.

