# Compiler architecture

The compilation stages are separate:

```text
*.ontology source
      ↓ Megaparsec
surface AST
      ↓ name resolution + semantic checks
canonical ontology graph
      ↓ compositional relational semantics
relative relational meaning
      ↓ PostgreSQL lowering
PostgreSQL schema value
      ↓ physical lowering
SQL syntax AST
      ↓ renderer
SQL text
```

`Ontology.Relational` is the canonical definition of ontology → relational meaning.
It has no cursor, current table, accumulator, State/Writer monad, or SQL naming. Each
ontology constructor denotes a relative relational value and larger meanings are composed
from their children.

## Compositional relational meaning

The core definition is structurally:

```text
scalar       = one relative column
Ref<T>       = one relative reference column
object       = the combination of its named field meanings
collection   = one dependent relation containing the element meaning
map          = one keyed dependent relation containing the result meaning
alternative = one tag plus one conditional dependent relation per branch
```

The main result types are:

```text
Row
  = columns
  + dependent relational values
  + relative rules

Dependent
  = relative path
  + boundary meaning
  + key components added at this boundary
  + presence guards
  + Row
```

A dependent automatically inherits its owner's eventual complete key; the semantic
definition states only the key components introduced by the boundary. Ordinary field
placement prefixes relative paths but does not descend into already-computed dependent
contents.

Population identity is explicit in `Population.populationKey`. Root populations and
`Ref<T>` discover which keyed named objects are independent populations; their value
meanings are still independently computed with the same equations. Set boundaries add
the member's Keyable value to the inherited semantic key; map boundaries add their named
arguments.

Optional values retain presence guards on their nonempty relational structure.

## PostgreSQL and SQL layers

The remaining compiler stages preserve the same separation.

`Ontology.Postgres` consumes only the relational meaning. It assigns deterministic
numbered table identifiers, materializes inherited keys, maps atoms to PostgreSQL types,
resolves references, nullability/presence, uniqueness, and records non-local integrity
obligations. Generated table names use a numeric prefix as the uniqueness authority; the
readable path suffix may therefore be safely truncated to PostgreSQL's identifier limit.
Ordinary column names remain semantic; collisions or overlong identifiers are errors
rather than silent renames.

`SQL.Syntax` is a small AST for exactly the SQL fragment we generate: tables, columns,
primary/unique/foreign/check constraints, expressions, selects, trigger functions, and
constraint triggers. It contains no ontology concepts.

`Postgres.Physical` lowers non-local PostgreSQL obligations into the SQL AST:

- an alternative tag and its branch row must agree in both directions;
- rows beneath an optional structured value require the corresponding presence marker;
- selector-based collection distinctness is checked across concrete selector sources,
  including separate alternative branch tables.

Foreign keys are represented as `ALTER TABLE ... ADD FOREIGN KEY` statements after all
table declarations, so reference cycles and declaration order do not affect installation.

`SQL.Render` renders SQL AST constructors. It contains no ontology, collection, map,
entity, or alternative rules.

The tutoring-company program is installed in PostgreSQL 16 in CI with
`ON_ERROR_STOP=1`, after Haskell compilation and semantic tests. Successful installation
is not a proof of complete runtime integrity or concurrency behavior.



## Executable reference specification

The Haskell definitions are intended to remain an executable semantic reference
as the compiler evolves. Future optimization rules and a Rust implementation
should be checked against that reference through a shared conformance corpus.
Compilation performance and generated SQL performance are measured separately.
See the [roadmap](roadmap.md) for the proposed optimization and generalization work.
