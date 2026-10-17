# Labeling equations and the `.label` workflow

This increment adds an English presentation interpretation to the existing
parameterized read compiler. It does not add HTML, timestamp formatting, a GUI,
another ontology, another selector compiler, or a copy of the JSON compiler.

## Boundary

```
No catalog       -> technical interpretation
Checked catalog  -> English interpretation

compilePrepared = compilePreparedWith technical
compileRead     = compileReadWith technical
```

A supplied but incomplete catalog is an error, not a request for mixed English
and technical output. `prepareLabeling` is the checked public construction path.
The internal `Labeling` record is also available for defining other policies;
hand-built policies are responsible for the same laws and preflight checks.

`Ontology.Labels.Types` defines the small algebra:

```haskell
data Labeling = Labeling
  { nameOf    :: Property -> Either String String
  , choicesAt :: Address -> Either String [(Literal, String)]
  }
```

`Property` distinguishes a directed/composed relation, a reconstructed semantic
key field, and a serializer-owned wrapper. Names are indexed by semantic
subjects, never table names, SQL column names, or concrete database IDs.

## Equations

For `S(r,b) = (b',rows,predicates)`, labeling `L`, and child projection `p`:

```
field_L(r,p,b) = (name_L(r,form), package(cardinality(r), S(r,b), J_L(p,b')))

J_L(record) = object of its selected labeled fields
J_L(set) = array of selected member payloads
J_L(map entry) = {name_L(mapKey): arguments, name_L(mapValue): payload}
J_L(terminal Ref T) = recursively labeled semantic key of T
J_L(alternative) = labeled discriminator plus the active selected branch
```

`selectRelation`, `selectStep`, `parameterTest`, `guardTests`, correlation, SQL
scope, and cardinality packaging do not receive labeling. In particular:

```
stored tag = "Active"       -- unchanged semantic condition
output tag = "Enrolled"     -- possible English expression
```

Finite value display is a fold over the supplied correspondence:

```
display([], raw) = raw
display((literal,caption):rest, raw) =
  CASE WHEN raw = literal THEN caption ELSE display(rest,raw)
```

The fold builds the existing `SQL.JsonCase` AST. Ordinary values and SQL nulls
remain ordinary values and nulls. No user wording is interpolated into raw SQL:
the existing renderer quotes `SQL.TextValue` values.

The full labeling environment is inherited. Each child already contains its
semantic address; references and inverses therefore do not require a separately
synchronized mirror-tree cursor. Terminal reference-key paths are grouped by
semantic segments before their output names are translated.

## Axioms used by this version

- Labels are ontology-local. They annotate named types, owned fields, map
  arguments, finite scalar values, alternative tags/cases, and inverse forms of
  those authored relationships. Views and traversal routes do not create new
  label identities.
- Crossing `Ref<T>` resets label lookup to T's ordinary ontology labels.
  There is no ref-local override block and no path-specific label namespace.
- Projection relations may contain reference/ownership plumbing. A separate
  adapter reduces such a relation to the first authored ontology relationship
  encountered from the current point, preserving direction and grammatical
  form. The catalog itself never sees the composed route.
- Type-block reuse is explicit: a named checked node supplies annotations to
  its reachable by-value occurrences. Distinct enum declarations with equal
  literal sets are not silently unified.
- A bare assignment is the common form: `= "Address";` supplies the same text
  for singular and plural. `singular` and `plural` are only needed when they
  differ; a specific form overrides the common form.
- A collection or map heading uses plural even for one runtime member; ordinary
  singular relationships use singular. These are presentation-form requests,
  not runtime row-count tests.
- Enum values and alternative possibilities have separate semantic identities.
  An alternative case caption also names that case's discriminator value.
- Technical output is stable; English-keyed JSON is presentation output. Do not
  reverse display labels into identifiers or action inputs.
- Equal keys are forbidden within a possible output object. Equal captions in
  separate nested objects are fine. Distinct branches of the same alternative
  may share a caption, but a branch cannot collide with a common sibling.

## File syntax

The file mirrors ontology structure without repeating types:

```text
language en;

labels Person {
  = "Person";
  plural = "People";

  code { = "Code"; }

  name {
    = "Name";
    inverse { = "Owner"; }
  }

  manager {
    = "Manager";
    inverse {
      = "Managed person";
      plural = "People managed";
    }
  }

  tags {
    = "Tag";
    plural = "Tags";
  }

  work {
    = "Work record";
    plural = "Work records";

    entries {
      argument year { = "Year"; }
      score { = "Score"; }
    }
  }
}

labels Status {
  case "active" = "Active";
  case "paused" = "Paused";
}

labels Choice {
  tag state { = "Status"; }
  case Active { = "Enrolled"; }
  case Empty { = "No enrollment"; }
}

system {
  mapKey = "Key";
  mapValue = "Details";
  contextValue = "Observed value";
  cutoff = "Truncated";
}
```

All strings use JSON escapes and support Unicode. Line and block comments are
allowed. `field name { ... }` is the explicit spelling for a field when its
name is also a label-language keyword; plain `name { ... }` is shorthand.

Structural navigation follows authored ontology structure only: `items`,
`entries`, `argument name`, `tag name`, and `case BranchName`.
There is deliberately no `ref { ... }`, exact-address block, or route entry.
Referenced contents use the target type's own annotations.

A bare assignment supplies both forms. These are equivalent unless an override
is present:

```text
city { = "City"; }

students {
  = "Student";
  plural = "Students";
}
```

`inverse { ... }` supplies the opposite-direction wording of the same authored
ontology relationship. It does not open another structural namespace.

Scalar enum cases remain typed: `case "active"`, `case 1`, `case true`.
Alternative branches use `case Active { ... }`; their captions remain attached
to that ontology alternative rather than to a particular view path.

A top-level assignment in `labels Person { ... }` is the type title. Titles are
valid ontology labels but are not yet emitted by the current JSON reader.

The machine-facing repair interface is the exhaustive JSON requirements report.
The optional `template` command now emits a parseable ontology-local skeleton
with the required semantic IDs as comments rather than introducing a second
path-addressing syntax.

## Exhaustive checking and export

```
World + selected PreparedViews
       -> finite possible output shapes
       -> required names and finite-value captions

requirements + resolved catalog
       -> missing / empty / duplicate / unknown / collision diagnostics
```

The `Shape` in `Labels.Plan` is a preflight output contract, not another SQL
compiler. It follows the read compiler's current serialization conventions,
including hidden wrappers, terminal reference keys, and branch-only properties.
It has no SQL dependency and does not inspect runtime values. Coverage includes
all enum values and possible selected branches, even if the fixture or current
database contains only one of them.

Collision checks inspect the combined possible object, not just each separate
`JsonObject` before `JsonMerge`. Exclusivity is local to that alternative
object; equal schema addresses in independent references do not establish it.

Semantic diagnostics are collected in one pass rather than failing at the first
missing entry. They contain stable codes, subjects and available source
locations. The parser also recovers at statement boundaries to report multiple
syntax errors when possible. Lexically unrecoverable files are rejected before
semantic checking; a partial parsed catalog is never executed.

Templates are an inventory, not automatic translations. An exported template
contains empty values and must fail `check` until completed. The compiler checks
coverage and shape, not the truth or quality of the supplied English wording.

## Command-line workflow

From the repository root, with GHC and the existing dependencies installed:

```sh
mkdir -p /tmp/ontology-label-build
ghc -O0 -Wall -Werror -package containers -package megaparsec -package mtl \
  -package scientific -package time -isrc \
  -outputdir /tmp/ontology-label-build \
  app/LabelMain.hs -o /tmp/ontology-labels

fixture=test/fixtures/labels.ontology
catalog=test/fixtures/labels.en.label

/tmp/ontology-labels "$fixture" Root Person 6 requirements
/tmp/ontology-labels "$fixture" Root Person 6 template > /tmp/person.en.label
/tmp/ontology-labels "$fixture" Root Person 6 check "$catalog"
/tmp/ontology-labels "$fixture" Root Person 6 sql "$catalog" > /tmp/person.en.sql
/tmp/ontology-labels "$fixture" Root Person 6 sql - > /tmp/person.technical.sql
```

`requirements` emits a JSON inventory with the missing entries; this export
command exits successfully. `check` emits a JSON report and exits nonzero on
errors. `sql` emits a parameterized `PREPARE` statement, not an invocation.
It assumes the corresponding generated schema has been installed.

The command describes one forward view with terminal references, with optional
center steps after the command/catalog: `field:name` (or `name`), `items`,
`entries`, `arg:name`, `case:N`, `tag`. The Haskell API accepts a list of actual
`PreparedView`s and supports their inverse and composed relationships too:

```haskell
required <- requirementsFor graph views
labels   <- prepareLabeling ontology graph views (Just catalog)
query    <- compilePreparedWith labels meaning schema view
```

An agent can export the inventory, edit only relevant entries, run `check`, and
repeat. The checker does not rewrite the catalog or invent rename migrations.
A disappeared semantic subject is diagnosed; the author decides its replacement.

## Verification

The existing technical read regression suite stays enabled. `test/LabelMain.hs`
checks complete and incomplete catalogs, independent syntax errors, source
reuse, conditional collisions, generated-template round trips, and equality of
the query-selection skeleton under different labeling interpretations.

It emits raw and English prepared statements and SQL functions for PostgreSQL
execution, with paired expected/actual JSON. The tests include named enum reuse,
separate enum domains with identical literals, numeric/boolean enum captions,
reference keys, compound keys, optionality, map/set identity, nested objects,
context wrappers, inverse relationships, alternatives and empty branches.

These are executable regression checks, not a proof for every possible
ontology. When a serialization convention is extended, its label-plan contract
and tests must be extended with it. No human-facing editor is required here.

