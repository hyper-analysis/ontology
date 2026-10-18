# Direction

## Current core

The modeling language, canonical ontology checks, compositional relational
interpretation, PostgreSQL DDL generation, and ontology-aware O-SQL compiler.
The independent in-memory O-SQL evaluator is not implemented.

## Executable specification

The Haskell implementation is intended to serve as the executable reference
specification: definitions that can be run to test the language's meaning.
The source language remains independent of Haskell. Existing tests are a
starting point for conformance, not a proof that every semantic rule is complete.

Before replacing an implementation, make observable behavior explicit:
accepted and rejected programs, diagnostics, semantic identity, ownership,
query values, nulls, failures and integrity constraints. Keep the reference
implementation available as an oracle for other implementations.

## Compilation and optimization rules

Introduce explicit, composable rewrite rules over compiler representations.
Each rule should state its semantic preconditions, the transformation it makes,
and the behavior it must preserve. Candidate work includes simplifying
intermediate expressions, removing demonstrably redundant generated operations,
and reducing repeated traversals or construction work.

O-SQL has ordered steps, null behavior and observable failures. A rewrite must
not duplicate or discard failing computations, reorder conditional evaluation,
erase identity distinctions, or turn an unordered set into an ordered sequence.
Equivalence needs regression and differential tests; performance needs benchmarks.

Measure two separate outcomes: compiler time/memory, and generated SQL execution
time/plans. Optimizing the compiler does not automatically optimize database work.

## Rust implementation

Build a Rust implementation against the executable reference specification.
The goal is faster compilation and predictable resource use, while keeping
the language and its semantics stable. Rust is the implementation choice;
performance gains remain a benchmarked goal rather than an assumed consequence.

Reuse the conformance corpus and compare implementations on valid and invalid
inputs. Compare semantic results and installed-schema behavior, rather than
requiring byte-identical SQL when equivalent lowerings differ.
Track parse/check/lowering time and memory on representative and large ontologies.
Keep the Haskell reference available during and after the port.

## Application compilation

A domain model contains structure that can inform more than storage. A future
application compiler could derive typed API contracts, read endpoints,
presentation inputs and application scaffolding from the checked ontology.
Application behavior and presentation policies need additional inputs;
an ontology alone does not specify a complete product.

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
