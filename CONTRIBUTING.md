# Contributing

Start with the school example and language reference, then run `make test`.
For compiler changes, also run PostgreSQL execution checks as described in
[development](docs/development.md).

Keep source-language rules in the checker and relational interpretation;
storage-specific rules belong in PostgreSQL lowering, and rendering belongs
in the SQL backend. Prefer definitions by input constructor and small,
domain-named composition operations.

Include a minimal ontology or O-SQL example when reporting an issue. For behavior
changes, include a regression case that distinguishes the previous and intended
result. Generated SQL changes need execution coverage.

Application generation is experimental on `feat/app-compilation`; discuss
changes there without adding application dependencies to the core package.
Contributions are provided under the project's Apache-2.0 license.

