# Direction

## Current core

The modeling language, canonical ontology checks, compositional relational
interpretation, PostgreSQL DDL generation, and ontology-aware O-SQL compiler.
The independent in-memory O-SQL evaluator is not implemented.

## Application compilation

A domain model contains structure that can inform more than storage. A future
application compiler could derive typed API contracts, read endpoints,
presentation inputs and application scaffolding from the checked ontology.
The intended boundary is explicit: application behavior and presentation policies
need additional inputs; an ontology alone does not specify a complete product.

The `feat/app-compilation` branch preserves an experimental compiler and runtime
templates separately. Its labels, projections and generated application files
are provisional and are not part of the core CLI or compatibility contract.
It is a prototype for investigation, not a production application platform.

## Other work

- Improve installation with published binaries and platform coverage.
- Stabilize the language and document conformance cases.
- Define schema evolution separately from fresh-schema generation.
- Expand backend checks, including transactional and concurrency behavior.

PostgreSQL is the current target. Additional targets should preserve semantic
identity and ownership rather than treating the ontology as table shorthand.

